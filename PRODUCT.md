# Branchline

<!-- impeccable:product-schema 1 -->

## Platform

macOS desktop.

## Stack

Native SwiftUI and AppKit with Swift Package Manager and short-lived Git processes. The implementation choices were delegated.

## Product Purpose

Inspect local changes, branch history and diffs. Stage files, make commits and push from one focused workspace. The supplied WebStorm screenshots establish the workflow and information density.

## Product Principles

- Keep the active repository, current branch and network destination visible.
- Load only the history page and file diff being viewed.
- Use Git's normal configuration, hooks and credentials.
- Make review and mutation distinct interactions. Selecting a branch browses it.
