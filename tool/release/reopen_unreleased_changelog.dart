#!/usr/bin/env dart

import 'dart:io';

void main(List<String> arguments) {
  if (arguments.isNotEmpty) {
    stderr.writeln('Usage: dart tool/release/reopen_unreleased_changelog.dart');
    exitCode = 64;
    return;
  }
  // The v0.20.2 tagged docs workflow calls this after switching to main.
  stdout.writeln('Core release notes are collected from landed pull requests.');
}
