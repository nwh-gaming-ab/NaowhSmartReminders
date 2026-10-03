-------------------------------------------------------------------------------
--  NaowhUI_SmartReminders_Verify.lua -- signature check for personalized packs.
--
--  Packs.lua's own header explains why an ordinary pack carries no license at
--  all: a string is text, and text can always be copied. This file exists for
--  the one case that argument does not cover -- naowh.gg's global download,
--  where the string is deliberately bound to one BattleTag before it ever
--  reaches a player. That binding is a real cryptographic signature (RSA-2048
--  PKCS#1 v1.5 / SHA-256): naowh.gg signs (battletag, expiry) with a private
--  key that never leaves the server, and this file verifies it with the
--  matching public key below, which is safe to ship because verifying a
--  signature and forging one require different halves of the keypair.
--
--  A pack with no ":LIC1:" segment is untouched by any of this -- Packs.lua
--  only calls into here when one is present.
-------------------------------------------------------------------------------
local ns = _G.NaowhUITankReminder
if not ns then return end

-- The public half of naowh.gg's pack-signing keypair. Rotating the server's
-- private key means updating this to match, in the same release.
local PACK_PUBLIC_KEY_N_HEX =
    "ac6168efc5bbff818d6e31f787d91a3cba158018b1f7b5fb588503f08857d2a502c3ae9ff4b7151d010a8f127f219f8f25" ..
    "938f609850838b22f254d8e5cedd0efc920e8db6153ab2f787344ab108b26fea227464ff101899464b6cc6370339c9e7c3" ..
    "20576d136f455e638614a653b4dfb67349f1c1952661f66a78e60ca640139a504c6401e06ae838618d906ce7f55286c158" ..
    "e8c69c47b8190f2c2a696afbd32b0be40a9eacb7160ba36a8e86937eeb92af306a76dc4f1472e6b976bcf111747eb27e60" ..
    "4037c439ac550aa1f39aee10d34bba36a955dc52be94282baa1a9d66c61f399eec97e74eea655f55861aff5c64860cd792" ..
    "ede63d8914b999d0862333"
local PACK_PUBLIC_KEY_E_HEX = "10001" -- 65537

-------------------------------------------------------------------------------
--  Pure Lua 5.1 SHA-256 (FIPS 180-4), using WoW's real `bit` global.
-------------------------------------------------------------------------------
local band, bor, bxor2, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift = bit.lshift, bit.rshift
local floor = math.floor
local byte, char, format = string.byte, string.char, string.format

local function bxor3(a, b, c) return bxor2(bxor2(a, b), c) end

local SHA_K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function rotr(x, n)
    return bor(rshift(x, n), lshift(x, 32 - n))
end

local function bytesToWord(s, i)
    local a, b, c, d = byte(s, i), byte(s, i + 1), byte(s, i + 2), byte(s, i + 3)
    return a * 0x1000000 + b * 0x10000 + c * 0x100 + d
end

local function wordToBytes(w)
    local a = rshift(w, 24)
    local b = band(rshift(w, 16), 0xFF)
    local c = band(rshift(w, 8), 0xFF)
    local d = band(w, 0xFF)
    return char(a, b, c, d)
end

-- Sum mod 2^32. Lua numbers are doubles, so the raw sum (up to ~7 32-bit
-- terms here) stays far inside the 53-bit safe-integer range before masking.
local function add32(a, b, c, d, e)
    local s = a + b + (c or 0) + (d or 0) + (e or 0)
    return band(s, 0xFFFFFFFF)
end

local function sha256Pad(msg)
    local len = #msg
    local bitLenHi = floor(len / 0x20000000)
    local bitLenLo = band(len * 8, 0xFFFFFFFF)
    local padLen = (56 - ((len + 1) % 64)) % 64
    return msg .. char(0x80) .. string.rep(char(0), padLen)
        .. wordToBytes(bitLenHi) .. wordToBytes(bitLenLo)
end

local function Sha256Digest(msg)
    msg = sha256Pad(msg)
    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

    local w = {}
    for blockStart = 1, #msg, 64 do
        for t = 0, 15 do
            w[t] = bytesToWord(msg, blockStart + t * 4)
        end
        for t = 16, 63 do
            local s0 = bxor3(rotr(w[t - 15], 7), rotr(w[t - 15], 18), rshift(w[t - 15], 3))
            local s1 = bxor3(rotr(w[t - 2], 17), rotr(w[t - 2], 19), rshift(w[t - 2], 10))
            w[t] = add32(w[t - 16], s0, w[t - 7], s1)
        end

        local a, b, c, d = h0, h1, h2, h3
        local e, f, g, h = h4, h5, h6, h7

        for t = 0, 63 do
            local S1 = bxor3(rotr(e, 6), rotr(e, 11), rotr(e, 25))
            local ch = bxor2(band(e, f), band(bnot(e), g))
            local temp1 = add32(h, S1, ch, SHA_K[t + 1], w[t])
            local S0 = bxor3(rotr(a, 2), rotr(a, 13), rotr(a, 22))
            local maj = bxor3(band(a, b), band(a, c), band(b, c))
            local temp2 = add32(S0, maj)

            h = g; g = f; f = e; e = add32(d, temp1)
            d = c; c = b; b = a; a = add32(temp1, temp2)
        end

        h0 = add32(h0, a); h1 = add32(h1, b); h2 = add32(h2, c); h3 = add32(h3, d)
        h4 = add32(h4, e); h5 = add32(h5, f); h6 = add32(h6, g); h7 = add32(h7, h)
    end

    return wordToBytes(h0) .. wordToBytes(h1) .. wordToBytes(h2) .. wordToBytes(h3)
        .. wordToBytes(h4) .. wordToBytes(h5) .. wordToBytes(h6) .. wordToBytes(h7)
end

local function BytesToHex(bin)
    local out = {}
    for i = 1, #bin do
        out[i] = format('%02x', byte(bin, i))
    end
    return table.concat(out)
end

-------------------------------------------------------------------------------
--  Minimal unsigned bignum, base 2^16 limbs, little-endian. See the spike
--  notes this was validated against: 16-bit limbs (not 24) keep every
--  schoolbook-multiply column sum inside a Lua double's 53-bit exact range
--  for a 2048-bit modulus.
-------------------------------------------------------------------------------
local BASE = 65536

local function bnTrim(a)
    local n = #a
    while n > 0 and a[n] == 0 do
        a[n] = nil
        n = n - 1
    end
    return a
end

local function bnFromHex(hex)
    hex = hex:gsub('^0x', ''):gsub('%s', '')
    if #hex % 2 == 1 then hex = '0' .. hex end
    local a = {}
    local i = #hex
    local limbIdx = 1
    while i > 0 do
        local start = i - 3
        local chunk = (start < 1) and hex:sub(1, i) or hex:sub(start, i)
        a[limbIdx] = tonumber(chunk, 16)
        limbIdx = limbIdx + 1
        i = i - 4
    end
    return bnTrim(a)
end

-- Big-endian binary string of exactly numBytes bytes.
local function bnToBytesBE(a, numBytes)
    local bytes = {}
    for i = 1, #a do
        local limb = a[i]
        bytes[#bytes + 1] = limb % 256
        bytes[#bytes + 1] = floor(limb / 256) % 256
    end
    while #bytes < numBytes do bytes[#bytes + 1] = 0 end
    while #bytes > numBytes do bytes[#bytes] = nil end
    local out = {}
    for i = numBytes, 1, -1 do
        out[#out + 1] = char(bytes[i])
    end
    return table.concat(out)
end

local function bnCmp(a, b)
    if #a ~= #b then return (#a < #b) and -1 or 1 end
    for i = #a, 1, -1 do
        if a[i] ~= b[i] then return (a[i] < b[i]) and -1 or 1 end
    end
    return 0
end

local function bnSub(a, b)
    local out = {}
    local borrow = 0
    for i = 1, #a do
        local x = a[i] - (b[i] or 0) - borrow
        if x < 0 then x = x + BASE; borrow = 1 else borrow = 0 end
        out[i] = x
    end
    return bnTrim(out)
end

local function bnShl1(a)
    local out = {}
    local carry = 0
    for i = 1, #a do
        local x = a[i] * 2 + carry
        if x >= BASE then out[i] = x - BASE; carry = 1 else out[i] = x; carry = 0 end
    end
    if carry == 1 then out[#a + 1] = 1 end
    return out
end

local function bnOrBit0(a)
    local out = {}
    for i = 1, #a do out[i] = a[i] end
    if #out == 0 then out[1] = 1 else out[1] = out[1] + 1 end
    return out
end

local function bnBitLength(a)
    if #a == 0 then return 0 end
    local top = a[#a]
    local bits = 0
    while top > 0 do top = floor(top / 2); bits = bits + 1 end
    return (#a - 1) * 16 + bits
end

local function bnTestBit(a, i)
    local limbIdx = floor(i / 16) + 1
    local limb = a[limbIdx]
    if not limb then return false end
    local bitInLimb = i % 16
    return floor(limb / (2 ^ bitInLimb)) % 2 == 1
end

local function bnMulFull(a, b)
    if #a == 0 or #b == 0 then return {} end
    local out = {}
    for i = 1, #a + #b do out[i] = 0 end
    for i = 1, #a do
        local ai = a[i]
        if ai ~= 0 then
            for j = 1, #b do
                out[i + j - 1] = out[i + j - 1] + ai * b[j]
            end
        end
    end
    local carry = 0
    for i = 1, #out do
        local v = out[i] + carry
        out[i] = v % BASE
        carry = floor(v / BASE)
    end
    while carry > 0 do
        out[#out + 1] = carry % BASE
        carry = floor(carry / BASE)
    end
    return bnTrim(out)
end

local function bnMod(a, m)
    local rem = {}
    local bits = bnBitLength(a)
    for i = bits - 1, 0, -1 do
        rem = bnShl1(rem)
        if bnTestBit(a, i) then rem = bnOrBit0(rem) end
        if bnCmp(rem, m) >= 0 then rem = bnSub(rem, m) end
    end
    return rem
end

local function bnModPow(base, exp, m)
    local result = { 1 }
    local b = bnMod(base, m)
    local bits = bnBitLength(exp)
    for i = bits - 1, 0, -1 do
        result = bnMod(bnMulFull(result, result), m)
        if bnTestBit(exp, i) then
            result = bnMod(bnMulFull(result, b), m)
        end
    end
    return result
end

-------------------------------------------------------------------------------
--  RSA PKCS#1 v1.5 SHA-256 signature verification (RFC 8017 SS8.2.2, SS9.2).
--  Verify-only: the public exponent is always small, so this never needs a
--  general-purpose modexp with a huge exponent or the private key.
-------------------------------------------------------------------------------
local SHA256_DIGESTINFO_PREFIX_HEX = '3031300d060960864801650304020105000420'

local function HexToBytes(hex)
    return (hex:gsub('..', function(cc) return char(tonumber(cc, 16)) end))
end

-- messageBytes: the exact bytes that were signed. signatureBytes: raw binary
-- signature (not hex). Returns true, or false plus a reason string.
local function RsaVerify(messageBytes, signatureBytes)
    local n = bnFromHex(PACK_PUBLIC_KEY_N_HEX)
    local e = bnFromHex(PACK_PUBLIC_KEY_E_HEX)
    local s = bnFromHex(BytesToHex(signatureBytes))

    local k = math.ceil(bnBitLength(n) / 8)
    if bnCmp(s, n) >= 0 then return false, 'signature_out_of_range' end

    local emInt = bnModPow(s, e, n)
    local em = bnToBytesBE(emInt, k)

    local hash = Sha256Digest(messageBytes)
    local t = HexToBytes(SHA256_DIGESTINFO_PREFIX_HEX) .. hash
    local psLen = k - 3 - #t
    if psLen < 8 then return false, 'modulus_too_small_for_sha256' end
    local expected = '\0\1' .. string.rep('\255', psLen) .. '\0' .. t

    if em == expected then return true end
    return false, 'signature_mismatch'
end

-------------------------------------------------------------------------------
--  License blob: [1 byte version][1 byte battletagLen N][N bytes battletag]
--  [4 bytes expiry, big-endian unix seconds][256 bytes RSA-2048 signature].
--  Signed message is battletag bytes followed by the 4 expiry bytes -- must
--  match lib/pack-signing.js's buildMessage() on the naowh.gg server exactly.
-------------------------------------------------------------------------------
local LICENSE_FORMAT_VERSION = 1
local SIGNATURE_BYTES = 256

-- encoded: the print-encoded blob (everything after ":LIC1:"). Returns
-- ok, reason, battletag. reason is only meaningful when ok is false, except
-- for "license_ok" which callers may show as a status.
function ns.CheckPackLicense(encoded)
    local LD = LibStub and LibStub("LibDeflate", true)
    if not LD then return false, "the serializer libraries are missing from this build" end

    local blob = LD:DecodeForPrint(encoded)
    if not blob then return false, "this pack's license is damaged (encoding)" end

    if #blob < 2 then return false, "this pack's license is damaged (too short)" end
    local version = byte(blob, 1)
    if version ~= LICENSE_FORMAT_VERSION then
        return false, "this pack's license needs a newer version of the addon"
    end
    local tagLen = byte(blob, 2)
    local expected = 2 + tagLen + 4 + SIGNATURE_BYTES
    if #blob ~= expected then return false, "this pack's license is damaged (size)" end

    local battletag = blob:sub(3, 2 + tagLen)
    local expiryBytes = blob:sub(3 + tagLen, 6 + tagLen)
    local signature = blob:sub(7 + tagLen, 6 + tagLen + SIGNATURE_BYTES)
    local e1, e2, e3, e4 = byte(expiryBytes, 1, 4)
    local expiry = e1 * 0x1000000 + e2 * 0x10000 + e3 * 0x100 + e4

    local message = battletag .. expiryBytes
    local sigOk, sigErr = RsaVerify(message, signature)
    if not sigOk then return false, "this pack's license signature is invalid (" .. tostring(sigErr) .. ")" end

    if time() > expiry then
        return false, "this pack's link to your account expired -- get a fresh one from naowh.gg"
    end

    local _, myTag = BNGetInfo()
    if not myTag or myTag == "" then
        return false, "could not read your Battle.net BattleTag to check this pack's license"
    end
    -- Compared without case. BattleTags preserve the capitals you chose but are unique
    -- without them, so this cannot match the wrong account. Exact comparison rejected
    -- people who typed "Silkytouch#1976" on the site when Battle.net holds
    -- "SilkyTouch#1976", which reads as the addon being broken rather than as a typo.
    if myTag:lower() ~= battletag:lower() then
        return false, format("this pack is licensed to %s, but you are logged in to Battle.net as %s", battletag, myTag)
    end

    return true, "license_ok", battletag
end
