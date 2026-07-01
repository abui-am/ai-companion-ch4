import Foundation
import Testing
@testable import Kokoro

@Test func configDecodesAlbertDefaults() throws {
    let json = """
    {
      "istftnet": {
        "upsample_kernel_sizes": [20, 12],
        "upsample_rates": [10, 6],
        "gen_istft_hop_size": 5,
        "gen_istft_n_fft": 20,
        "resblock_dilation_sizes": [[1,3,5],[1,3,5],[1,3,5]],
        "resblock_kernel_sizes": [3,7,11],
        "upsample_initial_channel": 512
      },
      "dim_in": 64,
      "dropout": 0.2,
      "hidden_dim": 512,
      "max_conv_dim": 512,
      "max_dur": 50,
      "multispeaker": true,
      "n_layer": 3,
      "n_mels": 80,
      "n_token": 178,
      "style_dim": 128,
      "text_encoder_kernel_size": 5,
      "plbert": {
        "hidden_size": 768,
        "num_attention_heads": 12,
        "intermediate_size": 2048,
        "max_position_embeddings": 512,
        "num_hidden_layers": 12,
        "dropout": 0.1
      },
      "vocab": { "a": 1 }
    }
    """
    let data = Data(json.utf8)
    let config = try JSONDecoder().decode(KokoroConfig.self, from: data)

    #expect(config.nToken == 178)
    #expect(config.plbert.embeddingSize == 128)
    #expect(config.plbert.hiddenAct == "gelu_new")
}

@Test func wavHeaderLooksValid() throws {
    let data = AudioWriter.wavData(samples: [0, 0.5, -0.5, 0.0], sampleRate: 24_000)
    #expect(data.prefix(4) == Data("RIFF".utf8))
    #expect(data[8..<12] == Data("WAVE".utf8))
}

@Test func smokeLoadsConvertedWeightsAndRunsTinyInference() throws {
    let converted = ProcessInfo.processInfo.environment["KOKORO_SMOKE_DIR"] ?? "/tmp/kokoro-converted"
    let convertedURL = URL(fileURLWithPath: converted)
    guard FileManager.default.fileExists(
        atPath: convertedURL.appendingPathComponent(ConvertedWeightsLayout.modelFileName, isDirectory: false).path
    ) else {
        return
    }

    let configURL = convertedURL.appendingPathComponent("config.json", isDirectory: false)
    let model = try KModel(
        configURL: configURL,
        weightsURL: convertedURL.appendingPathComponent(ConvertedWeightsLayout.modelFileName, isDirectory: false)
    )
    let voices = VoiceLoader(
        baseDirectory: convertedURL.appendingPathComponent(ConvertedWeightsLayout.voicesDirectoryName, isDirectory: true)
    )
    let pipeline = KPipeline(model: model, voices: voices)
    let result = try pipeline.synthesize(phonemes: "abc", voice: "af_heart")

    #expect(!result.audio.isEmpty)
}
