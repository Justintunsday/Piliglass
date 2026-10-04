#ifndef PILI_HTTP_BODY_CODEC_H
#define PILI_HTTP_BODY_CODEC_H
#include <stddef.h>
#include <stdint.h>

typedef struct {
  int status; /* 0 success; 1 malformed; 2 output limit; 3 allocation failure */
  uint8_t *bytes;
  size_t count;
} PiliBodyDecodeResult;

/* codec 1 = Dart IO gzip/zlib, 2 = Brotli. All state is per invocation. */
PiliBodyDecodeResult pili_http_body_decode(const uint8_t *input, size_t count,
                                         int codec, size_t maximum_output);
void pili_http_body_release(uint8_t *bytes);
#endif
