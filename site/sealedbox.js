// libsodium-compatible sealed boxes (crypto_box_seal), which GitHub requires for
// repository secrets. X25519 + XSalsa20-Poly1305 come from TweetNaCl
// (vendor/nacl-fast.min.js); the nonce is BLAKE2b-192(ephemeral_pk || recipient_pk).
(function (global) {
  "use strict";

  // ---- BLAKE2b (RFC 7693), unkeyed, variable output length -------------------
  // 64-bit words are kept as pairs of 32-bit halves: v[2*i] = low, v[2*i+1] = high.
  var IV = new Uint32Array([
    0xf3bcc908, 0x6a09e667, 0x84caa73b, 0xbb67ae85, 0xfe94f82b, 0x3c6ef372, 0x5f1d36f1, 0xa54ff53a,
    0xade682d1, 0x510e527f, 0x2b3e6c1f, 0x9b05688c, 0xfb41bd6b, 0x1f83d9ab, 0x137e2179, 0x5be0cd19,
  ]);
  var SIGMA = [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
    [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
    [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
    [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
    [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
    [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
    [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
    [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
  ];

  function add64(v, a, b) { // v[a] += v[b]
    var lo = v[a] + v[b];
    var hi = v[a + 1] + v[b + 1] + (lo / 0x100000000 >= 1 ? 1 : 0);
    v[a] = lo >>> 0;
    v[a + 1] = hi >>> 0;
  }
  function addWord(v, a, m, i) { // v[a] += m[i]
    var lo = v[a] + m[i];
    var hi = v[a + 1] + m[i + 1] + (lo / 0x100000000 >= 1 ? 1 : 0);
    v[a] = lo >>> 0;
    v[a + 1] = hi >>> 0;
  }
  function xorRotate(v, a, b, n) { // v[a] = rotr64(v[a] ^ v[b], n)
    var lo = v[a] ^ v[b];
    var hi = v[a + 1] ^ v[b + 1];
    if (n === 32) {
      v[a] = hi; v[a + 1] = lo;
    } else if (n < 32) {
      v[a] = ((lo >>> n) | (hi << (32 - n))) >>> 0;
      v[a + 1] = ((hi >>> n) | (lo << (32 - n))) >>> 0;
    } else {
      n -= 32;
      v[a] = ((hi >>> n) | (lo << (32 - n))) >>> 0;
      v[a + 1] = ((lo >>> n) | (hi << (32 - n))) >>> 0;
    }
  }
  function G(v, m, a, b, c, d, x, y) {
    add64(v, a, b); addWord(v, a, m, x); xorRotate(v, d, a, 32);
    add64(v, c, d); xorRotate(v, b, c, 24);
    add64(v, a, b); addWord(v, a, m, y); xorRotate(v, d, a, 16);
    add64(v, c, d); xorRotate(v, b, c, 63);
  }

  function compress(h, block, counter, last) {
    var v = new Uint32Array(32);
    var m = new Uint32Array(32);
    var i;
    for (i = 0; i < 16; i++) { v[i] = h[i]; v[i + 16] = IV[i]; }
    v[24] ^= counter >>> 0;
    v[25] ^= Math.floor(counter / 0x100000000) >>> 0;
    if (last) { v[28] = ~v[28] >>> 0; v[29] = ~v[29] >>> 0; }
    for (i = 0; i < 32; i++) {
      m[i] = block[4 * i] | (block[4 * i + 1] << 8) | (block[4 * i + 2] << 16) | (block[4 * i + 3] << 24);
    }
    for (i = 0; i < 12; i++) {
      var s = SIGMA[i];
      G(v, m, 0, 8, 16, 24, s[0] * 2, s[1] * 2);
      G(v, m, 2, 10, 18, 26, s[2] * 2, s[3] * 2);
      G(v, m, 4, 12, 20, 28, s[4] * 2, s[5] * 2);
      G(v, m, 6, 14, 22, 30, s[6] * 2, s[7] * 2);
      G(v, m, 0, 10, 20, 30, s[8] * 2, s[9] * 2);
      G(v, m, 2, 12, 22, 24, s[10] * 2, s[11] * 2);
      G(v, m, 4, 14, 16, 26, s[12] * 2, s[13] * 2);
      G(v, m, 6, 8, 18, 28, s[14] * 2, s[15] * 2);
    }
    for (i = 0; i < 16; i++) h[i] = (h[i] ^ v[i] ^ v[i + 16]) >>> 0;
  }

  function blake2b(input, outlen) {
    var h = new Uint32Array(IV);
    h[0] ^= (0x01010000 ^ outlen) >>> 0;
    var block = new Uint8Array(128);
    var offset = 0;
    var counter = 0;
    // All full blocks except the final one.
    while (input.length - offset > 128) {
      block.set(input.subarray(offset, offset + 128));
      counter += 128;
      compress(h, block, counter, false);
      offset += 128;
    }
    block.fill(0);
    block.set(input.subarray(offset));
    counter += input.length - offset;
    compress(h, block, counter, true);
    var out = new Uint8Array(outlen);
    for (var i = 0; i < outlen; i++) out[i] = (h[i >> 2] >>> (8 * (i & 3))) & 0xff;
    return out;
  }

  // ---- Sealed box ---------------------------------------------------------------
  function seal(message, recipientPublicKey) {
    var nacl = global.nacl;
    var ephemeral = nacl.box.keyPair();
    var nonceInput = new Uint8Array(64);
    nonceInput.set(ephemeral.publicKey, 0);
    nonceInput.set(recipientPublicKey, 32);
    var nonce = blake2b(nonceInput, 24);
    var boxed = nacl.box(message, nonce, recipientPublicKey, ephemeral.secretKey);
    var out = new Uint8Array(32 + boxed.length);
    out.set(ephemeral.publicKey, 0);
    out.set(boxed, 32);
    ephemeral.secretKey.fill(0);
    return out;
  }

  function fromBase64(text) {
    var binary = atob(text);
    var out = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
    return out;
  }

  function toBase64(bytes) {
    var binary = "";
    for (var i = 0; i < bytes.length; i += 0x8000) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    }
    return btoa(binary);
  }

  /// Encrypts a string for a GitHub repository secret. `publicKeyBase64` comes from
  /// GET /repos/{owner}/{repo}/actions/secrets/public-key. Returns base64.
  function encryptSecret(value, publicKeyBase64) {
    var message = new TextEncoder().encode(value);
    return toBase64(seal(message, fromBase64(publicKeyBase64)));
  }

  global.SealedBox = { blake2b: blake2b, seal: seal, encryptSecret: encryptSecret, toBase64: toBase64, fromBase64: fromBase64 };
})(typeof self !== "undefined" ? self : this);
