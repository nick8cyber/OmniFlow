---
title: Local build & install runbook
status: done
owner: agents
updated: 2026-11-11
tags: [build, codesign, tcc, install]
---

# Local build & install runbook

How to build and install OmniFlow locally **without wiping TCC permissions**
(Microphone, Accessibility, Screen Recording, Input Monitoring).

> [!WARNING] Why permissions get wiped
> macOS TCC binds grants to the code's **designated requirement** = bundle ID +
> signing certificate. An ad-hoc signature (`CODESIGN_IDENTITY=-`) makes every
> rebuild a different app for TCC → all grants re-prompt. The `.dev` bundle ID
> (`com.nick8cyber.omniflow.dev`) is a *separate* TCC identity with its own
> grant set. Never install an ad-hoc build over `/Applications/OmniFlow.app`.

## Build

- [ ] `make check` — typecheck (`-warnings-as-errors`) + tests + plist lint
- [ ] `git diff --check` — no whitespace breakage
- [ ] `make APP_NAME=OmniFlow BUNDLE_ID=com.nick8cyber.omniflow CODESIGN_IDENTITY="Developer ID Application" ARCH="$(uname -m)"` → `build/OmniFlow.app`

The installed app is signed `Developer ID Application: Nikita Somov (4A9AUNB2QS)`;
the cert lives in the login keychain (`security find-identity -v -p codesigning`).
Same signer + same bundle ID ⇒ grants carry over silently.

> [!NOTE] Dev builds
> Plain `make` produces `OmniFlow Dev.app` (`.dev` bundle, hammer icon) for
> side-by-side use. It is a *different* TCC identity: grant it once and the
> grants persist while the signature stays stable. It never touches the prod
> app's grants — and must not replace it.

## Verify before install

- [ ] `codesign --verify --deep --strict build/OmniFlow.app` → no output
- [ ] **DR match**: `codesign -dr - build/OmniFlow.app` vs `codesign -dr - /Applications/OmniFlow.app` — identical byte-for-byte ⇒ permissions preserved
- [ ] `codesign -dv` → `Identifier=com.nick8cyber.omniflow`, `TeamIdentifier=4A9AUNB2QS`
- [ ] `strings build/OmniFlow.app/Contents/MacOS/OmniFlow | grep -c "<new-UI-string>"` — feature is actually in the binary

## Install

- [ ] `pgrep -lf OmniFlow` → must be empty (replacing a running bundle can kill
      an active dictation; **never kill the user's app without asking**)
- [ ] `mv /Applications/OmniFlow.app /tmp/OmniFlow.app.bak`
- [ ] `ditto build/OmniFlow.app /Applications/OmniFlow.app`
- [ ] `codesign --verify --deep --strict /Applications/OmniFlow.app`
- [ ] `open /Applications/OmniFlow.app && pgrep -lf OmniFlow` → running

Rollback: `mv /tmp/OmniFlow.app.bak /Applications/OmniFlow.app`.

## Rules

- Build inside your own worktree (`build/` stays isolated); branch always,
  never commit to `main`.
- First launch of a new TCC identity (`.dev`) triggers permission prompts —
  don't launch it casually.
- Verified 2026-11-11: `feat/gemini-transcription-mode` build installed with
  zero permission prompts; DR match confirmed before install.
