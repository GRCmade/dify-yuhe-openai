## Yuhe OpenAI
`yuhe-openai` is a maintained fork of the upstream OpenAI Dify plugin for OpenAI-compatible gateways that proxy the Responses API through stricter upstream implementations.

It keeps the OpenAI model coverage and provider schema, but adjusts the request transformation layer so GPT-5 / Responses API models work against gateways that reject some otherwise-public fields.

## Why This Fork Exists
This fork was created to maintain compatibility with Yuhe-style OpenAI-compatible gateways where `/v1/responses` can fail with upstream `502` errors when incompatible fields are forwarded.

The maintained changes include:

- stripping `metadata` from Responses API requests
- stripping `presence_penalty` and `frequency_penalty` for stricter Responses-compatible gateways
- converting system prompts from `role="system"` to `role="developer"` for gateways that reject `system` on `/v1/responses`
- keeping credential validation and runtime invocation behavior aligned for GPT-5-class models
- narrowing GPT-5-family parameter rules so unsupported fields are not exposed in the model parameter UI

## Overview
OpenAI offers a comprehensive set of models for various tasks, including text generation, image generation, vision, audio generation, text-to-speech (TTS), speech-to-text (STT), embeddings, moderation, and reasoning.

This plugin allows developers to integrate LLMs such as GPT-3.5, GPT-4, GPT-5, and the o1 family (including custom fine-tuned versions) via the API, with support for function calling.

## Configure
After installing the plugin, configure your OpenAI-compatible settings in the Model Provider section. This includes your API key (find it [here](https://platform.openai.com/account/api-keys)) and optional Organization ID and API Base. Save to use Yuhe OpenAI.

<img src="./_assets/openai-01.png" width="400" />

## Publish This Plugin
This repository is structured to be published as a standalone Dify plugin repository.

Official Dify references:

- [Publish to Individual GitHub Repository](https://docs.dify.ai/en/develop-plugin/publishing/marketplace-listing/release-to-individual-github-repo)
- [Package as Local File and Share](https://docs.dify.ai/en/develop-plugin/publishing/marketplace-listing/release-by-file)
- [Publishing FAQ](https://docs.dify.ai/en/develop-plugin/publishing/faq/faq)

### Release Checklist
- Keep the `author` field in `manifest.yaml` and `provider/openai.yaml` consistent with your GitHub ID in lowercase. Dify plugin daemon only accepts lowercase `author` values matching `^[a-z0-9_-]{1,64}$`. This repository uses `grcmade`.
- Complete remote debugging before packaging.
- Make the GitHub repository public if you want other Dify users to install it directly from GitHub.

### Package the Plugin
With the Dify CLI installed, go to the directory above this repository and run:

```bash
dify plugin package ./dify-yuhe-openai
```

Dify generates a `.difypkg` file in the current directory.

### Publish Options
- GitHub repository: push the plugin source to a public GitHub repository and share the repository URL. Dify users can install it from GitHub with the repository URL and version.
- Local file: upload the generated `.difypkg` from the Dify Plugins page for private distribution or internal testing.
- Marketplace: submit it separately if you want official review and one-click installation from the Dify Marketplace.

### Notes for Self-Hosted Dify
- If installation fails with `PluginDaemonBadRequestError: plugin_unique_identifier is not valid`, recheck that both `author` fields match your GitHub ID, then package again.
- If self-hosted Dify rejects a non-marketplace plugin with a signature error, Dify's FAQ says you can set `FORCE_VERIFYING_SIGNATURE=false` in `docker/.env` for trusted test environments before restarting Dify.
- If the error still includes an identifier like `Author/plugin:version@checksum`, make sure `author` is lowercase. `GRCmade/...` is invalid, while `grcmade/...` is accepted by the current daemon regex.
