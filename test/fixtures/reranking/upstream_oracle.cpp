// Build against the exact pinned upstream llama.cpp. See doc/native_reranking.md.
// The server oracle independently checks output zero; this driver emits every
// native class and the input tokens that upstream's rerank framing consumes.
#include "llama.h"
#include "build-info.h"
#include "nlohmann/json.hpp"

#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

using json = nlohmann::ordered_json;

static std::vector<llama_token> tokenize(const llama_vocab * vocab, const std::string & text, bool special) {
    int n = -llama_tokenize(vocab, text.data(), text.size(), nullptr, 0, false, special);
    if (n < 0) throw std::runtime_error("token sizing failed");
    std::vector<llama_token> result(n);
    if (n > 0 && llama_tokenize(vocab, text.data(), text.size(), result.data(), n, false, special) != n) {
        throw std::runtime_error("tokenization failed");
    }
    return result;
}

static void replace_all(std::string & text, const std::string & from, const std::string & to) {
    size_t pos = 0;
    while ((pos = text.find(from, pos)) != std::string::npos) {
        text.replace(pos, from.size(), to);
        pos += to.size();
    }
}

static std::vector<llama_token> frame(const llama_model * model, const std::string & query, const std::string & document) {
    const auto * vocab = llama_model_get_vocab(model);
    const char * named = llama_model_chat_template(model, "rerank");
    if (named) {
        std::string prompt(named);
        replace_all(prompt, "{query}", query);
        replace_all(prompt, "{document}", document);
        return tokenize(vocab, prompt, true);
    }
    // Pinned upstream tools/server/server-common.cpp:format_prompt_rerank.
    std::vector<llama_token> result;
    const auto append = [&](const std::vector<llama_token> & input) { result.insert(result.end(), input.begin(), input.end()); };
    auto eos = llama_vocab_eos(vocab);
    if (eos == LLAMA_TOKEN_NULL) eos = llama_vocab_sep(vocab);
    if (llama_vocab_get_add_bos(vocab)) result.push_back(llama_vocab_bos(vocab));
    append(tokenize(vocab, query, false));
    if (llama_vocab_get_add_eos(vocab)) result.push_back(eos);
    if (llama_vocab_get_add_sep(vocab)) result.push_back(llama_vocab_sep(vocab));
    append(tokenize(vocab, document, false));
    if (llama_vocab_get_add_eos(vocab)) result.push_back(eos);
    return result;
}

int main(int argc, char ** argv) {
    if (argc != 3) return 2;
    llama_backend_init();
    auto mp = llama_model_default_params();
    mp.n_gpu_layers = 0;
    auto * model = llama_model_load_from_file(argv[1], mp);
    if (!model) return 3;
    auto cp = llama_context_default_params();
    cp.n_ctx = 2048;
    cp.n_batch = 2048;
    cp.n_ubatch = 2048;
    cp.n_threads = 4;
    cp.n_threads_batch = 4;
    cp.embeddings = true;
    auto * ctx = llama_init_from_model(model, cp);
    if (!ctx || llama_pooling_type(ctx) != LLAMA_POOLING_TYPE_RANK) return 4;
    const auto classes = llama_model_n_cls_out(model);
    json result = {{"upstream_commit", llama_commit()}, {"labels", json::array()}, {"cases", json::array()}};
    for (uint32_t i = 0; i < classes; ++i) {
        const char * label = llama_model_cls_label(model, i);
        result["labels"].push_back(label ? json(label) : json(nullptr));
    }
    std::ifstream input(argv[2]);
    json fixture = json::parse(input);
    for (const auto & item : fixture["cases"]) {
        json output = {{"id", item["id"]}, {"scores", json::array()}, {"tokens", json::array()}};
        for (const auto & document : item["documents"]) {
            const auto tokens = frame(model, item["query"], document);
            if (tokens.empty() || tokens.size() > 2048) return 5;
            if (auto mem = llama_get_memory(ctx)) llama_memory_clear(mem, true);
            auto batch = llama_batch_init(tokens.size(), 0, 1);
            batch.n_tokens = tokens.size();
            for (size_t i = 0; i < tokens.size(); ++i) {
                batch.token[i] = tokens[i]; batch.pos[i] = i;
                batch.n_seq_id[i] = 1; batch.seq_id[i][0] = 0; batch.logits[i] = 1;
            }
            const bool encoder = llama_model_has_encoder(model) && !llama_model_has_decoder(model);
            const int status = encoder ? llama_encode(ctx, batch) : llama_decode(ctx, batch);
            if (status != 0) return 6;
            llama_synchronize(ctx);
            const float * values = llama_get_embeddings_seq(ctx, 0);
            if (!values) return 7;
            output["scores"].push_back(std::vector<float>(values, values + classes));
            output["tokens"].push_back(tokens);
            llama_batch_free(batch);
        }
        result["cases"].push_back(output);
    }
    std::cout << result.dump(2) << std::endl;
    llama_free(ctx);
    llama_model_free(model);
    llama_backend_free();
}
