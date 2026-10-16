// Model-free inputs reproducing the mid-word boundary reported in #673.
// Compile against unmodified LiteRT-LM v0.18.0 merger sources; no inference.
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "omni/asr/timestamp_text_merger.h"

using litert::omni::SingleThreadedStageWithDeque;
using litert::omni::asr::TimestampTextMerger;
using litert::omni::asr::Word;

class FixtureWords : public SingleThreadedStageWithDeque<std::vector<Word>> {
public:
  void Add(const std::string &text) {
    std::istringstream input(text);
    std::vector<Word> words;
    for (std::string word; input >> word;) {
      words.push_back({word, std::nullopt});
    }
    PushOutput(std::move(words));
  }

private:
  bool NeedScheduleInternal() const override { return false; }
  absl::Status ScheduleInternal() override { return absl::OkStatus(); }
};

int main(int argc, char **argv) {
  if (argc != 3) return 64;
  FixtureWords words;
  TimestampTextMerger merger(&words, std::stof(argv[1]));
  const std::vector<std::string> chunks =
      std::string(argv[2]) == "single"
          ? std::vector<std::string>{"Go go, never never stop."}
          : std::vector<std::string>{
                "And so my fellow Americans ask not.",
                "ask not. what your country can do for you.",
                "One tree can do for you, ask what you can do for your country."};
  std::string transcript;
  auto drain = [&]() {
    while (merger.HasOutput()) {
      auto output = merger.GetOutput().value();
      if (!output.confirmed_text.empty()) {
        if (!transcript.empty()) transcript += " ";
        transcript += output.confirmed_text;
      }
    }
  };
  for (const auto &chunk : chunks) {
    words.Add(chunk);
    auto status = merger.Schedule();
    if (!status.ok()) return 1;
    drain();
  }
  auto status = merger.Flush();
  if (!status.ok()) return 3;
  drain();
  std::cout << transcript << '\n';
}
