#!/usr/bin/env python3
"""Find orphaned chat previews and safely remove them on main."""
import json
import logging
import os
from pathlib import Path
import re
import subprocess
import sys

from hf_space_deploy import status_of
from preview_guard import Superseded, delete_preview


REPOSITORY = 'leehack/llamadart'
NAMESPACE = 'leehack'
SPACE_PREFIX = f'{NAMESPACE}/llamadart-chat-pr-'
PR_NUMBER = r'[1-9][0-9]*'
SPACE_ID = re.compile(rf'{SPACE_PREFIX}({PR_NUMBER})')


class SweepFailed(Exception):
    def __init__(self, operation, target, error, status=None):
        if status is None:
            status = status_of(error)
        status_text = f'HTTP {status}' if type(status) is int else 'no HTTP status'
        super().__init__(f'{operation} {target} {status_text} {type(error).__name__}')


def pr_is_closed(number, space):
    status = None
    try:
        result = subprocess.run(
            ['gh', 'api', '--include', f'repos/{REPOSITORY}/pulls/{number}'],
            capture_output=True, timeout=30)
        headers, _, body = result.stdout.replace(b'\r\n', b'\n').partition(b'\n\n')
        match = re.match(rb'HTTP/[0-9.]+ ([0-9]{3})(?: |\n|$)', headers)
        status = int(match[1]) if match else None
        if status == 404:
            return False
        result.check_returncode()
        pr = json.loads(body)
        if status != 200 or str(pr['number']) != number or pr['state'] not in ('closed', 'open'):
            raise ValueError('Invalid live PR response')
        return pr['state'] == 'closed'
    except Exception as error:
        raise SweepFailed('read_pr', space, error, status) from None


def list_closed_previews(api):
    try:
        candidates = {}
        for space in api.list_spaces(author=NAMESPACE):
            match = SPACE_ID.fullmatch(space.id)
            if match:
                candidates[match[1]] = space.id
    except Exception as error:
        raise SweepFailed('list_spaces', NAMESPACE, error) from None
    closed = [number for number, space in candidates.items() if pr_is_closed(number, space)]
    return sorted(closed, key=int)[:256]


def delete_closed_preview(api, number):
    if not re.fullmatch(PR_NUMBER, number):
        raise ValueError('Invalid preview PR number')
    space = f'{SPACE_PREFIX}{number}'

    def recheck():
        if not pr_is_closed(number, space):
            raise Superseded()

    try:
        delete_preview(api, space, before=recheck)
    except Superseded:
        return
    except SweepFailed:
        raise
    except Exception as error:
        raise SweepFailed('delete_repo', space, error) from None


def main(args):
    operation = 'preview_sweep'
    try:
        if (os.environ.get('GITHUB_REPOSITORY') != REPOSITORY
                or os.environ.get('GITHUB_REF') != 'refs/heads/main'
                or os.environ.get('GITHUB_EVENT_NAME') not in ('schedule', 'workflow_dispatch')
                or args not in (['list'], ['delete'])):
            raise ValueError('Invalid sweep invocation')
        operation = args[0]
        from huggingface_hub import HfApi
        api = HfApi(token=os.environ['HF_TOKEN'])
        if operation == 'list':
            numbers = list_closed_previews(api)
            with Path(os.environ['GITHUB_OUTPUT']).open('a', encoding='utf-8') as output:
                output.write(f'prs={json.dumps(numbers)}\n')
        else:
            delete_closed_preview(api, os.environ['PREVIEW_PR_NUMBER'])
    except SweepFailed as error:
        raise SystemExit(str(error)) from None
    except Exception as error:
        raise SystemExit(str(SweepFailed(operation, NAMESPACE, error))) from None


if __name__ == '__main__':
    # The CLI reports only sanitized provider failures.
    logging.disable(logging.CRITICAL)
    main(sys.argv[1:])
