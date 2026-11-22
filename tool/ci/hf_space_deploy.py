#!/usr/bin/env python3
"""Upload a folder to a Hugging Face static Space, creating it only if missing.

Hugging Face applies a separate quota to Space creation, even with exist_ok.
Probe existing Spaces first so regular uploads avoid that creation endpoint.
Only HTTP 429 is retried, with at most MAX_ATTEMPTS tries per call and one
MAX_TOTAL_WAIT budget shared by probe, create, upload and optional history
squash. A numeric Retry-After is honored; an HTTP-date, negative or missing
value falls back to jittered exponential backoff. Every other error fails at
once so a broken deploy stays visible.

--max-folder-bytes rejects oversized or unreadable folders and symlinks before
any Hub call. Existing Spaces warn at 750 MB of usedStorage.
--squash-history collapses the Space's main history after a successful upload.
A terminal squash error reports the HTTP status and error type.
"""
import argparse
import os
import random
import stat
import sys
import time

MAX_ATTEMPTS = 5
MAX_TOTAL_WAIT = 240.0
MAX_BACKOFF = 30.0
BASE_BACKOFF = 5.0
STORAGE_WARN_BYTES = 750_000_000


def status_of(error):
    return getattr(getattr(error, 'response', None), 'status_code', None)


def retry_after(error):
    value = getattr(getattr(error, 'response', None), 'headers', {}).get('Retry-After')
    try:
        seconds = float(value)
    except (TypeError, ValueError):
        return None
    return seconds if seconds >= 0 else None


class Budget:
    waited = 0.0


class SquashHistoryError(RuntimeError):
    pass


def with_retry(label, call, budget, sleep=time.sleep, jitter=random.random, log=print):
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            return call()
        except Exception as error:
            if status_of(error) != 429 or attempt == MAX_ATTEMPTS:
                raise
            delay = retry_after(error)
            if delay is None:
                delay = min(MAX_BACKOFF, BASE_BACKOFF * 2 ** (attempt - 1)) * (0.5 + jitter() / 2)
            if budget.waited + delay > MAX_TOTAL_WAIT:
                raise
            log(f'{label}: HTTP 429 on attempt {attempt}/{MAX_ATTEMPTS}; retrying in {delay:.0f}s',
                file=sys.stderr)
            sleep(delay)
            budget.waited += delay


def used_storage_of(info):
    for key in ('used_storage', 'usedStorage'):
        value = getattr(info, key, None)
        if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
            return value
    return None


def folder_size_bytes(folder):
    folder = os.fspath(folder)

    def raise_walk_error(error):
        raise error

    try:
        # Check prefixes before a separator, '.' or '..' can hide a link from lstat.
        prefixes = [folder]
        while (parent := os.path.dirname(prefixes[-1])) and parent != prefixes[-1]:
            prefixes.append(parent)
        for prefix in reversed(prefixes):
            root_mode = os.lstat(prefix).st_mode
            if stat.S_ISLNK(root_mode):
                raise ValueError("Deploy folder contains a symlink at '.'")
        if not stat.S_ISDIR(root_mode):
            raise ValueError('Deploy folder must be a directory')
        size = 0
        for directory, dirs, files in os.walk(
                folder, followlinks=False, onerror=raise_walk_error):
            for name in dirs + files:
                path = os.path.join(directory, name)
                entry = os.lstat(path)
                if stat.S_ISLNK(entry.st_mode):
                    relative = os.path.relpath(path, folder)
                    raise ValueError(f'Deploy folder contains a symlink at {relative!r}')
                if stat.S_ISREG(entry.st_mode):
                    size += entry.st_size
        return size
    except OSError as error:
        relative = os.path.relpath(error.filename or folder, folder)
        raise ValueError(f'Cannot scan deploy folder at {relative!r}') from None


def deploy(api, repo, folder, commit_message, delete_patterns, public, *,
           squash_history=False, max_folder_bytes=None, **retry_options):
    # upload_folder expands '~'; preflight must measure the same folder it uploads.
    folder = os.path.expanduser(os.fspath(folder))
    if max_folder_bytes is not None:
        if max_folder_bytes <= 0:
            raise ValueError('--max-folder-bytes must be positive')
        actual = folder_size_bytes(folder)
        if actual > max_folder_bytes:
            raise ValueError(
                f'Folder size {actual} bytes exceeds --max-folder-bytes limit {max_folder_bytes} bytes')

    budget = Budget()
    try:
        info = with_retry('repo_info', budget=budget, call=lambda: api.repo_info(
            repo_id=repo, repo_type='space'), **retry_options)
    except Exception as error:
        if status_of(error) != 404:
            raise
        create_options = {'private': False} if public else {}
        with_retry('create_repo', budget=budget, call=lambda: api.create_repo(
            repo_id=repo, repo_type='space', space_sdk='static', exist_ok=True, **create_options),
            **retry_options)
    else:
        used = used_storage_of(info)
        if used is not None and used >= STORAGE_WARN_BYTES:
            log = retry_options.get('log', print)
            log(f'repo_info: Space usedStorage is {used / 1_000_000:.1f} MB (limit 1000.0 MB)',
                file=sys.stderr)

    with_retry('upload_folder', budget=budget, call=lambda: api.upload_folder(
        repo_id=repo, repo_type='space', folder_path=folder, revision='main',
        delete_patterns=delete_patterns, commit_message=commit_message),
        **retry_options)
    if squash_history:
        try:
            with_retry('super_squash_history', budget=budget,
                       call=lambda: api.super_squash_history(
                           repo_id=repo, repo_type='space', branch='main',
                           commit_message=commit_message),
                       **retry_options)
        except Exception as error:
            status = status_of(error)
            http = f'HTTP {status}' if type(status) is int else 'HTTP status unavailable'
            raise SquashHistoryError(
                f'super_squash_history: failed ({http}, {type(error).__name__})') from None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--folder', required=True)
    parser.add_argument('--commit-message', required=True)
    parser.add_argument('--delete-pattern', action='append', required=True)
    parser.add_argument('--public', action='store_true')
    parser.add_argument('--squash-history', action='store_true')
    parser.add_argument('--max-folder-bytes', type=int)
    args = parser.parse_args(argv)

    from huggingface_hub import HfApi

    try:
        deploy(HfApi(token=os.environ['HF_TOKEN']), args.repo, args.folder, args.commit_message,
               args.delete_pattern, args.public, squash_history=args.squash_history,
               max_folder_bytes=args.max_folder_bytes)
    except SquashHistoryError as error:
        raise SystemExit(str(error)) from None


if __name__ == '__main__':
    main()
