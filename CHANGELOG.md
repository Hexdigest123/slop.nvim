# Changelog

## 1.0.0 (2026-10-19)


### Features

* **acp:** start sessions in the agent's ask-before-acting mode ([545e683](https://github.com/Hexdigest123/slop.nvim/commit/545e683c261aa5aad472da8b5a78ed4ba25d72cd))
* **ai/acp:** NDJSON JSON-RPC ACP client with sessions, permission policy and fs read ([38d2f50](https://github.com/Hexdigest123/slop.nvim/commit/38d2f505a0af45ca7b9e2cf7d97c8c039c52a9c6))
* **ai/context:** budgeted FIM context, neighbours, recent edits, ring, files and rules ([97ec66f](https://github.com/Hexdigest123/slop.nvim/commit/97ec66fe07cc7b5e23ba314fe73a65edecfd9b8d))
* **ai:** chat and FIM providers (mistral, openai-compatible, anthropic, gemini, llama.cpp) ([080ad7b](https://github.com/Hexdigest123/slop.nvim/commit/080ad7b62c386580fc74da96bd4f4724dba895f3))
* **ai:** provider timeout and max_tokens are floors for every module's requests ([3c932f1](https://github.com/Hexdigest123/slop.nvim/commit/3c932f1fff3374c176d43adbcccf90ee99cdac38))
* **ai:** request started/finished events ([e4b207f](https://github.com/Hexdigest123/slop.nvim/commit/e4b207fa0b0639059256b3cb96a90c9dd204d7f3))
* **cloak:** decoration-provider masks, cloak.nvim-compatible rules, preview line, integrations, core.secrets provider ([95ce342](https://github.com/Hexdigest123/slop.nvim/commit/95ce34289a039e3885e8d86aa837138eeae3155c))
* **commit:** AI commit message ghost text in gitcommit buffers ([ea60b4d](https://github.com/Hexdigest123/slop.nvim/commit/ea60b4df599e2f2c4952654e52569fa410b02109))
* **complete:** streamed FIM ghost text with typed-through sync, cycling, cache and cmp source ([d47b9b9](https://github.com/Hexdigest123/slop.nvim/commit/d47b9b91314aba996e350d62669e4a72b9179166))
* **context:** sticky scope headers (replaces nvim-treesitter-context) ([cf6fa33](https://github.com/Hexdigest123/slop.nvim/commit/cf6fa332318ce231c060d17bb407f3764647d0fc))
* **core/git:** async git helpers, staged diff, scissors parser ([a561f2a](https://github.com/Hexdigest123/slop.nvim/commit/a561f2ac3a5cd80460dbb47d6796ad4725c9fb5a))
* **core/http:** curl requests with streaming decoders, cancel, timeout, cookie jar ([7ea8755](https://github.com/Hexdigest123/slop.nvim/commit/7ea8755c9d50e88fe6d9149b0040e0e96ef16a18))
* **core/secrets:** public spans(), display providers, one capability load per config ([0fd7264](https://github.com/Hexdigest123/slop.nvim/commit/0fd7264f860f1425a3fcec1e0674c299a6addb79))
* **core/term:** hidden terminal jobs with float/split/vsplit slots, send and exit handling ([3cb8610](https://github.com/Hexdigest123/slop.nvim/commit/3cb8610cc6125af1f6ad6b26370b2bb90e63a6b2))
* **core/ts:** enclosing scopes, signatures and empty-block detection ([7718076](https://github.com/Hexdigest123/slop.nvim/commit/77180769a361efe19981607816fb3913f964e95e))
* **core/ui/diff:** applied inline diff review with per-hunk accept/reject ([8745294](https://github.com/Hexdigest123/slop.nvim/commit/87452940b10305f40411781bdc8dff5097271a51))
* **core/ui/float:** bordered floats with sizing, region anchoring and resize ([294a8df](https://github.com/Hexdigest123/slop.nvim/commit/294a8df54badd3671e26cb52da7805169ae2994d))
* **core/ui/ghost:** inline ghost text with counter and partial accepts ([3443223](https://github.com/Hexdigest123/slop.nvim/commit/34432234bcc78e1701978509d3497775ef8f319a))
* **core/ui/input:** multi-line prompt float with history and completion hook ([24c8c7d](https://github.com/Hexdigest123/slop.nvim/commit/24c8c7d6088c9a0dd134095fdfe15d5d53880e28))
* **core/ui/picker:** fzf-lua, builtin float and vim.ui.select backends ([79ef691](https://github.com/Hexdigest123/slop.nvim/commit/79ef69166111b6be5b247aa4f65f5a1bb9575a52))
* **core/ui/scratch:** named scratch buffers with split, float and winbar ([4835837](https://github.com/Hexdigest123/slop.nvim/commit/4835837f049fa1266cd339d37b01cb48f156ed74))
* **core/ui/spinner:** spinner styles, timer and native progress messages ([214adc2](https://github.com/Hexdigest123/slop.nvim/commit/214adc264b1c7f9f02df73b272918b5c8754b3ee))
* **core:** bootstrap, config, registry, commands, keymaps, health, log, events, project ([dc750f8](https://github.com/Hexdigest123/slop.nvim/commit/dc750f8317ffca536061dfb181e67827b8097e16))
* **core:** secrets default path, shared interface stubs and module specs ([af2b3dc](https://github.com/Hexdigest123/slop.nvim/commit/af2b3dc3dea69972f8d12df69b833e38270fd779))
* **doc:** AI doc comments for the item at the cursor ([9081f65](https://github.com/Hexdigest123/slop.nvim/commit/9081f6543885a3e557262e0aedba70187ab9f5f9))
* **edit:** ACP region edits with live progress, replacement protocol, inline diff review, presets and refine ([ebbd472](https://github.com/Hexdigest123/slop.nvim/commit/ebbd472a72d6cf17cd7a03c93a9c3c169eeebef4))
* **manifest:** context ([f81896b](https://github.com/Hexdigest123/slop.nvim/commit/f81896b12fd9707202c51e46d700f7fc763d5163))
* **manifest:** load cloak on fzf-lua and telescope previews ([a325310](https://github.com/Hexdigest123/slop.nvim/commit/a32531077a4e76b1cb85589516f7485cd5d13e24))
* **manifest:** marks keys ([6404bbf](https://github.com/Hexdigest123/slop.nvim/commit/6404bbf30431c473f1666c084b37a65b9f3f5e43))
* **manifest:** progress and doc ([efc3484](https://github.com/Hexdigest123/slop.nvim/commit/efc348422671380f4c71977b9c1e606c95d1ef6a))
* **manifest:** todo ([e1065e5](https://github.com/Hexdigest123/slop.nvim/commit/e1065e5a7f49d9a94b7e95986c6ca14450aeb03b))
* **marks:** per-project file marks with cursor memory and quick menu ([29d17d0](https://github.com/Hexdigest123/slop.nvim/commit/29d17d0b481febeee83944e2ab6af5a0f768755d))
* **plugin:** detect *.rest files as http ([faa8f9b](https://github.com/Hexdigest123/slop.nvim/commit/faa8f9b89c67f47597f3669e6080c3fa1600668f))
* **progress:** LSP, native and AI progress window ([54bc72b](https://github.com/Hexdigest123/slop.nvim/commit/54bc72bc7eed55e7e938f82de199531bf8058a0d))
* **rest:** AI gen/fix through ai.chat or ACP with redaction and diff preview ([8ce2138](https://github.com/Hexdigest123/slop.nvim/commit/8ce21386b0e0795220af43133a303855a29801dc))
* **rest:** discovery, curl runner, result view, picker, history and env selection ([ffe8e64](https://github.com/Hexdigest123/slop.nvim/commit/ffe8e641e67c3b2109d3cac3ef6cef2c9b4f6a77))
* **rest:** pure .http parser, variable resolution, env files and chaining ([6b67f64](https://github.com/Hexdigest123/slop.nvim/commit/6b67f647fed6f34e846466c94a3fa6d280afcd96))
* **term:** float terminal toggle, split/vsplit layouts, send selection and commands ([84effc0](https://github.com/Hexdigest123/slop.nvim/commit/84effc0a59449a81ec4928ca6d63508db9ba18db))
* **todo:** highlight, list and jump between todo comments ([fd65f1d](https://github.com/Hexdigest123/slop.nvim/commit/fd65f1d8b220cee1bddeb2de3c803953359ea0f4))


### Bug Fixes

* **acp:** refuse agent file reads outside the project root ([a0e8f33](https://github.com/Hexdigest123/slop.nvim/commit/a0e8f332cdeb28cabed171c92ab8318446f1d3a5))
* **ai:** read text from reasoning models' chunked content ([13b05b3](https://github.com/Hexdigest123/slop.nvim/commit/13b05b34381ba572b38cf5a813426f5e73c9d608))
* **context:** redraw on FileType (parser and highlighter start there) ([f321f22](https://github.com/Hexdigest123/slop.nvim/commit/f321f227b98e3e4c9177efb7b3fcd0bedaeea041))
* **core/secrets:** per-hunk diff redaction for multi-line rules, is_cloaked look-back for PEM bodies ([3f30c8f](https://github.com/Hexdigest123/slop.nvim/commit/3f30c8fef2dc72dc35fa5f9a6f3b3c9bfe7843c1))
* **core/ui/spinner:** own augroup, apart from the progress module ([c2d720e](https://github.com/Hexdigest123/slop.nvim/commit/c2d720e22ebce72aace3a55a0c35a1d243f6d657))
* **doc:** find items from decorators, attributes and sh buffers ([2f59339](https://github.com/Hexdigest123/slop.nvim/commit/2f593392316dd8fda3ae51dcf00a4c3198c576dd))
* **doc:** hint at max_tokens when a reasoning model returns nothing ([28a847c](https://github.com/Hexdigest123/slop.nvim/commit/28a847c1a0e75ee1516f45afa4fee13bf89dbdf1))
* **progress:** flatten multi-line messages (a newline left the window blank) ([3557d1d](https://github.com/Hexdigest123/slop.nvim/commit/3557d1df263eef5a772ab96c187c33c4d5da435a))


### Performance Improvements

* **ai/context:** size the raw line window from the budget ([4f80618](https://github.com/Hexdigest123/slop.nvim/commit/4f806185f76361491f16c3185c1ccbf7b6613ff0))
* **progress:** draw LSP report bursts once per tick ([5c0c53b](https://github.com/Hexdigest123/slop.nvim/commit/5c0c53b5547a5f5d67ffe24eedc9d3ad3286a77f))
* **todo:** reconcile signs per window without re-creating unchanged marks ([3e23fbe](https://github.com/Hexdigest123/slop.nvim/commit/3e23fbe1bc3d3e8adaff557dab870a1cbe6a5a9c))
