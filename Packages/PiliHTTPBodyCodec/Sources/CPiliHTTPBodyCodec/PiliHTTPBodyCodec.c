#include "PiliHTTPBodyCodec.h"
#include <brotli/decode.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static int append(PiliBodyDecodeResult *result, const uint8_t *chunk,
                  size_t count, size_t maximum) {
  if (count > maximum - result->count) return 2;
  if (!count) return 0;
  uint8_t *next = realloc(result->bytes, result->count + count);
  if (!next) return 3;
  memcpy(next + result->count, chunk, count);
  result->bytes = next;
  result->count += count;
  return 0;
}

static PiliBodyDecodeResult gzip_decode(const uint8_t *input, size_t count,
                                        size_t maximum) {
  PiliBodyDecodeResult result = {0, NULL, 0};
  if (count > UINT_MAX) { result.status = 1; return result; }
  z_stream stream;
  memset(&stream, 0, sizeof(stream));
  /* Dart IO GZipCodec accepts gzip and zlib envelopes, not raw deflate. */
  if (inflateInit2(&stream, MAX_WBITS + 32) != Z_OK) {
    result.status = 3;
    return result;
  }
  stream.next_in = (Bytef *)input;
  stream.avail_in = (uInt)count;
  uint8_t chunk[32768];
  for (;;) {
    stream.next_out = chunk;
    stream.avail_out = sizeof(chunk);
    int status = inflate(&stream, Z_NO_FLUSH);
    result.status = append(&result, chunk, sizeof(chunk) - stream.avail_out, maximum);
    if (result.status) break;
    if (status == Z_STREAM_END) {
      if (stream.avail_in == 0) break;
      /* Concatenated members are also accepted by Dart IO GZipCodec. */
      if (inflateReset2(&stream, MAX_WBITS + 32) != Z_OK) { result.status = 1; break; }
      continue;
    }
    /* Preserve decodeBytes' existing Dart IO behavior: an incomplete member
       can return the bytes decoded before EOF. This is not an integrity claim. */
    if ((status == Z_OK || status == Z_BUF_ERROR) && stream.avail_in == 0 && stream.avail_out != 0) break;
    if (status != Z_OK) { result.status = 1; break; }
  }
  inflateEnd(&stream);
  return result;
}

static PiliBodyDecodeResult brotli_decode(const uint8_t *input, size_t count,
                                          size_t maximum) {
  PiliBodyDecodeResult result = {0, NULL, 0};
  BrotliDecoderState *state = BrotliDecoderCreateInstance(NULL, NULL, NULL);
  if (!state) { result.status = 3; return result; }
  size_t available_input = count;
  const uint8_t *next_input = input;
  uint8_t chunk[32768];
  for (;;) {
    size_t available_output = sizeof(chunk);
    uint8_t *next_output = chunk;
    BrotliDecoderResult status = BrotliDecoderDecompressStream(
      state, &available_input, &next_input, &available_output, &next_output, NULL);
    result.status = append(&result, chunk, sizeof(chunk) - available_output, maximum);
    if (result.status) break;
    if (status == BROTLI_DECODER_RESULT_SUCCESS) {
      /* Dart's decoder checks for unused bytes at stream end. */
      if (available_input != 0) result.status = 1;
      break;
    }
    if (status != BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT) { result.status = 1; break; }
  }
  BrotliDecoderDestroyInstance(state);
  return result;
}

PiliBodyDecodeResult pili_http_body_decode(const uint8_t *input, size_t count,
                                         int codec, size_t maximum_output) {
  PiliBodyDecodeResult result = codec == 1 ? gzip_decode(input, count, maximum_output)
                                         : brotli_decode(input, count, maximum_output);
  if (result.status) {
    free(result.bytes);
    result.bytes = NULL;
    result.count = 0;
  }
  return result;
}

void pili_http_body_release(uint8_t *bytes) { free(bytes); }
