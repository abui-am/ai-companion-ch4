#pragma once

#include <stddef.h>
#include <stdint.h>

void micServerUploadBegin();
void micServerUploadLoop();
bool micServerUploadIsReady();
bool micServerUploadSend(const uint8_t *pcm, size_t bytes);
