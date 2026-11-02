# Solar Open accepted content-channel preservation

The fixture binds the real Solar Open 100B template and unchanged primary
llama.cpp `8642541b255bfb5dc39cd351a178be09013a55d6` (the current native/Web pin).
It captures two different questions:

- The primary **template-derived** parser rejects the synthetic repeated-channel
  output in #1596, both finally and through whole/bytewise sessions. This repair
  does not adopt that rejection or claim upstream admission/model generation.
- Dart's existing Solar PEG grammar admits the output. The accompanying C++
  mapper oracle builds that same no-tools grammar using the current primary
  builder, then calls the primary mapper. Its AST is reasoning `Plan.`, content
  `Sunny. `, content ` more`; lossless mapping returns `Sunny.  more`.

The prior Dart mapper overwrote the first content node, returning ` more`.
The prior no-tools stream used raw thinking-tag splitting and exposed the second
channel frame. Only Solar now opts into concatenated content mapping and its
existing PEG channel parser for no-tools streaming. Other format defaults,
reasoning mapping, admission, grammar and schema policy are unchanged.

Per-fragment whitespace is preserved; the existing final-edge trimming policy
is applied after concatenation. The parser/stream matrix covers whole output,
every two-way split, code-unit chunks, empty/whitespace channels, tools on/off,
thinking on/off and accepted truncated or rejected required-tool controls.

Solar Open 100B weights were unavailable in the standard local cache. These
primary emissions, exact template bytes and durable tests are the affected-family
substitute; unrelated models are not used as Solar qualification. No new
runtime/platform support or real Solar model inference is claimed.
