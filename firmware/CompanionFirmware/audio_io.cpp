#include "audio_io.h"

#include <Arduino.h>
#include <driver/i2s.h>

#include "config.h"
#include "protocol.h"

static const i2s_port_t MIC_PORT = I2S_NUM_0;
static const i2s_port_t SPK_PORT = I2S_NUM_1;

void audioIoInit() {
#if HAS_MIC
    i2s_config_t micConfig = {
        .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
        .sample_rate = COMPANION_UPLINK_SAMPLE_RATE,
        .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
        .channel_format = MIC_CHANNEL_LEFT ? I2S_CHANNEL_FMT_ONLY_LEFT : I2S_CHANNEL_FMT_ONLY_RIGHT,
        .communication_format = I2S_COMM_FORMAT_STAND_I2S,
        .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count = 4,
        .dma_buf_len = 256,
        .use_apll = false,
        .tx_desc_auto_clear = false,
        .fixed_mclk = 0,
    };
    i2s_driver_install(MIC_PORT, &micConfig, 0, NULL);

    i2s_pin_config_t micPins = {
        .bck_io_num = PIN_MIC_BCLK,
        .ws_io_num = PIN_MIC_WS,
        .data_out_num = I2S_PIN_NO_CHANGE,
        .data_in_num = PIN_MIC_DIN,
    };
    i2s_set_pin(MIC_PORT, &micPins);
#else
    Serial.println("HAS_MIC=0, skipping mic I2S init (no hardware yet)");
#endif

    i2s_config_t spkConfig = {
        .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_TX),
        .sample_rate = COMPANION_DOWNLINK_SAMPLE_RATE,
        .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
        .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,
        .communication_format = I2S_COMM_FORMAT_STAND_I2S,
        .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count = 4,
        .dma_buf_len = 256,
        .use_apll = false,
        .tx_desc_auto_clear = true,
        .fixed_mclk = 0,
    };
    i2s_driver_install(SPK_PORT, &spkConfig, 0, NULL);

    i2s_pin_config_t spkPins = {
        .bck_io_num = PIN_SPK_BCLK,
        .ws_io_num = PIN_SPK_WS,
        .data_out_num = PIN_SPK_DOUT,
        .data_in_num = I2S_PIN_NO_CHANGE,
    };
    i2s_set_pin(SPK_PORT, &spkPins);

    Serial.println("I2S mic + speaker channels ready");
}

size_t audioIoReadUplinkFrame(uint8_t *out, size_t outCapacity) {
#if HAS_MIC
    size_t bytesRead = 0;
    esp_err_t err = i2s_read(MIC_PORT, out, outCapacity, &bytesRead, pdMS_TO_TICKS(200));
    if (err != ESP_OK) {
        Serial.printf("i2s mic read failed: %d\n", err);
        return 0;
    }
    return bytesRead;
#else
    return 0;
#endif
}

void audioIoWriteDownlink(const int16_t *monoSamples, size_t sampleCount) {
    // Duplicate mono samples into an interleaved stereo buffer — most class-D
    // I2S amps (e.g. MAX98357A) pick L or R via a hardware pin, so writing
    // identical data to both slots plays correctly regardless of wiring.
    static int16_t stereoBuf[2 * (COMPANION_DOWNLINK_FRAME_BYTES / sizeof(int16_t))];
    size_t maxSamples = sizeof(stereoBuf) / sizeof(stereoBuf[0]) / 2;
    if (sampleCount > maxSamples) {
        sampleCount = maxSamples;
    }
    for (size_t i = 0; i < sampleCount; i++) {
        stereoBuf[2 * i] = monoSamples[i];
        stereoBuf[2 * i + 1] = monoSamples[i];
    }

    size_t bytesWritten = 0;
    esp_err_t err = i2s_write(SPK_PORT, stereoBuf, sampleCount * 2 * sizeof(int16_t),
                               &bytesWritten, pdMS_TO_TICKS(200));
    if (err != ESP_OK) {
        Serial.printf("i2s speaker write failed: %d\n", err);
    }
}
