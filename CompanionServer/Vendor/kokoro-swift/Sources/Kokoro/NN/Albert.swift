import Foundation
import MLX
import MLXFast
import MLXNN

final class AlbertEmbeddings: Module {
    @ModuleInfo(key: "word_embeddings") var wordEmbeddings: Embedding
    @ModuleInfo(key: "position_embeddings") var positionEmbeddings: Embedding
    @ModuleInfo(key: "token_type_embeddings") var tokenTypeEmbeddings: Embedding
    @ModuleInfo(key: "LayerNorm") var layerNorm: LayerNorm

    init(config: KokoroConfig.PLBERT, vocabSize: Int) {
        _wordEmbeddings.wrappedValue = Embedding(
            embeddingCount: vocabSize,
            dimensions: config.embeddingSize
        )
        _positionEmbeddings.wrappedValue = Embedding(
            embeddingCount: config.maxPositionEmbeddings,
            dimensions: config.embeddingSize
        )
        _tokenTypeEmbeddings.wrappedValue = Embedding(
            embeddingCount: config.typeVocabSize,
            dimensions: config.embeddingSize
        )
        _layerNorm.wrappedValue = LayerNorm(
            dimensions: config.embeddingSize,
            eps: config.layerNormEps
        )
    }

    func callAsFunction(_ inputIDs: MLXArray, tokenTypeIDs: MLXArray? = nil) -> MLXArray {
        let batch = inputIDs.dim(0)
        let length = inputIDs.dim(1)
        let positions = broadcast(MLXArray.arange(length), to: [batch, length])
        let tokenTypes = tokenTypeIDs ?? MLXArray.zeros([batch, length], dtype: .int32)
        let embeddings = wordEmbeddings(inputIDs)
            + positionEmbeddings(positions)
            + tokenTypeEmbeddings(tokenTypes)
        return layerNorm(embeddings)
    }
}

final class AlbertAttention: Module {
    @ModuleInfo(key: "query") var query: Linear
    @ModuleInfo(key: "key") var key: Linear
    @ModuleInfo(key: "value") var value: Linear
    @ModuleInfo(key: "dense") var dense: Linear
    @ModuleInfo(key: "LayerNorm") var layerNorm: LayerNorm

    let numAttentionHeads: Int
    let hiddenSize: Int
    let headSize: Int

    init(config: KokoroConfig.PLBERT) {
        self.numAttentionHeads = config.numAttentionHeads
        self.hiddenSize = config.hiddenSize
        self.headSize = config.hiddenSize / config.numAttentionHeads

        _query.wrappedValue = Linear(config.hiddenSize, config.hiddenSize, bias: true)
        _key.wrappedValue = Linear(config.hiddenSize, config.hiddenSize, bias: true)
        _value.wrappedValue = Linear(config.hiddenSize, config.hiddenSize, bias: true)
        _dense.wrappedValue = Linear(config.hiddenSize, config.hiddenSize, bias: true)
        _layerNorm.wrappedValue = LayerNorm(dimensions: config.hiddenSize, eps: config.layerNormEps)
    }

    func callAsFunction(_ hiddenStates: MLXArray, attentionMask: MLXArray?) -> MLXArray {
        let batch = hiddenStates.dim(0)
        let length = hiddenStates.dim(1)

        let queries = query(hiddenStates)
            .reshaped(batch, length, numAttentionHeads, headSize)
            .transposed(0, 2, 1, 3)
        let keys = key(hiddenStates)
            .reshaped(batch, length, numAttentionHeads, headSize)
            .transposed(0, 2, 1, 3)
        let values = value(hiddenStates)
            .reshaped(batch, length, numAttentionHeads, headSize)
            .transposed(0, 2, 1, 3)

        let maskMode: MLXFast.ScaledDotProductAttentionMaskMode = if let attentionMask {
            .array(attentionMask)
        } else {
            .none
        }

        let scale = 1.0 / sqrt(Float(headSize))
        var attended = MLXFast.scaledDotProductAttention(
            queries: queries,
            keys: keys,
            values: values,
            scale: scale,
            mask: maskMode
        )
        attended = attended.transposed(0, 2, 1, 3).reshaped(batch, length, hiddenSize)
        return layerNorm(hiddenStates + dense(attended))
    }
}

final class AlbertLayer: Module {
    @ModuleInfo(key: "attention") var attention: AlbertAttention
    @ModuleInfo(key: "ffn") var ffn: Linear
    @ModuleInfo(key: "ffn_output") var ffnOutput: Linear
    @ModuleInfo(key: "full_layer_layer_norm") var fullLayerLayerNorm: LayerNorm

    let config: KokoroConfig.PLBERT

    init(config: KokoroConfig.PLBERT) {
        self.config = config
        _attention.wrappedValue = AlbertAttention(config: config)
        _ffn.wrappedValue = Linear(config.hiddenSize, config.intermediateSize, bias: true)
        _ffnOutput.wrappedValue = Linear(config.intermediateSize, config.hiddenSize, bias: true)
        _fullLayerLayerNorm.wrappedValue = LayerNorm(
            dimensions: config.hiddenSize,
            eps: config.layerNormEps
        )
    }

    func callAsFunction(_ hiddenStates: MLXArray, attentionMask: MLXArray?) -> MLXArray {
        let attentionOutput = attention(hiddenStates, attentionMask: attentionMask)
        let ffOutput = ffnOutput(geluNew(ffn(attentionOutput)))
        return fullLayerLayerNorm(attentionOutput + ffOutput)
    }
}

final class AlbertLayerGroup: Module {
    let albertLayers: [AlbertLayer]

    init(config: KokoroConfig.PLBERT) {
        self.albertLayers = (0 ..< config.innerGroupNum).map { _ in AlbertLayer(config: config) }
    }

    func callAsFunction(_ hiddenStates: MLXArray, attentionMask: MLXArray?) -> MLXArray {
        var output = hiddenStates
        for layer in albertLayers {
            output = layer(output, attentionMask: attentionMask)
        }
        return output
    }
}

final class AlbertTransformer: Module {
    @ModuleInfo(key: "embedding_hidden_mapping_in") var embeddingHiddenMappingIn: Linear
    let albertLayerGroups: [AlbertLayerGroup]
    let config: KokoroConfig.PLBERT

    init(config: KokoroConfig.PLBERT) {
        self.config = config
        _embeddingHiddenMappingIn.wrappedValue = Linear(
            config.embeddingSize,
            config.hiddenSize,
            bias: true
        )
        self.albertLayerGroups = (0 ..< config.numHiddenGroups).map { _ in AlbertLayerGroup(config: config) }
    }

    func callAsFunction(_ hiddenStates: MLXArray, attentionMask: MLXArray?) -> MLXArray {
        var output = embeddingHiddenMappingIn(hiddenStates)
        for layerIndex in 0 ..< config.numHiddenLayers {
            let groupIndex = Int(
                Float(layerIndex) / (Float(config.numHiddenLayers) / Float(config.numHiddenGroups))
            )
            output = albertLayerGroups[groupIndex](output, attentionMask: attentionMask)
        }
        return output
    }
}

public final class CustomAlbert: Module {
    let embeddings: AlbertEmbeddings
    let encoder: AlbertTransformer

    public init(config: KokoroConfig.PLBERT, vocabSize: Int) {
        self.embeddings = AlbertEmbeddings(config: config, vocabSize: vocabSize)
        self.encoder = AlbertTransformer(config: config)
    }

    public func callAsFunction(
        _ inputIDs: MLXArray,
        attentionMask: MLXArray? = nil,
        tokenTypeIDs: MLXArray? = nil
    ) -> MLXArray {
        let embedded = embeddings(inputIDs, tokenTypeIDs: tokenTypeIDs)
        let additiveMask: MLXArray? = if let attentionMask {
            attentionMask
                .asType(embedded.dtype)
                .expandedDimensions(axes: [1, 2])
                .log()
        } else {
            nil
        }
        return encoder(embedded, attentionMask: additiveMask)
    }
}
