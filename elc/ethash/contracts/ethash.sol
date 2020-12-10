pragma solidity ^0.6.2;

import "./binary.sol";
import "./keccak512.sol";

contract Ethash {

    using LittleEndian for bytes;
    using Keccak512 for bytes;

    uint32 constant hashWords = 16;
    uint32 constant hashBytes = 64;
    uint32 constant datasetParents = 256;
    uint32 constant mixBytes = 128;         // Width of mix
	uint32 constant loopAccesses = 64;      // Number of accesses in hashimoto loop

    function D(uint32 d) pure private { // for debug
        bytes memory hexstr = "0123456789abcdef";
        bytes memory b = "00000000";
        b[0] = hexstr[(d>>28)&0xf];
        b[1] = hexstr[(d>>24)&0xf];
        b[2] = hexstr[(d>>20)&0xf];
        b[3] = hexstr[(d>>16)&0xf];
        b[4] = hexstr[(d>>12)&0xf];
        b[5] = hexstr[(d>>8)&0xf];
        b[6] = hexstr[(d>>4)&0xf];
        b[7] = hexstr[(d>>0)&0xf];
        revert(string(b));
    }

    constructor() public {}
    // fnv is an algorithm inspired by the FNV hash, which in some cases is used as
    // a non-associative substitute for XOR. Note that we multiply the prime with
    // the full 32-bit input, in contrast with the FNV-1 spec which multiplies the
    // prime with one byte (octet) in turn.
    function fnv(uint32 a, uint32 b) internal pure returns(uint32) {
        return a*0x01000193 ^ b;
    }

    // fnvHash mixes in data into mix using the ethash fnv method.
    function fnvHash(uint32[] memory mix, uint32[] memory data, uint32 offset) internal pure {
        for(uint32 i = 0; i < mix.length; i++) {
            mix[i] = mix[i]*0x01000193 ^ data[i+offset];
        }
    }

    // generateDatasetItem combines data from 256 pseudorandomly selected cache nodes,
    // and hashes that to compute a single dataset node.
    function generateDatasetItem(uint32[] memory cache, uint32 index) internal pure returns(bytes memory) {
        // Calculate the number of theoretical rows (we use one buffer nonetheless)
        uint32 rows = uint32(cache.length / hashWords);

        // Initialize the mix
        bytes memory mix = new bytes(hashBytes);
        mix.PutUint32(0, cache[(index%rows)*hashWords]^index);
        for (uint32 i = 1; i < hashWords; i++) {
            mix.PutUint32(i*4, cache[(index%rows)*hashWords+uint32(i)]);
        }

        mix = mix.sha3_512();

        // Convert the mix to uint32s to avoid constant bit shifting
        uint32[] memory intMix = new uint32[](hashWords);
        for (uint32 i = 0; i < intMix.length; i++) {
            intMix[i] = mix.Uint32(i*4);
        }
        // fnv it with a lot of random cache nodes based on index
        for (uint32 i = 0; i < datasetParents; i++) {
            uint32 parent = fnv(index^i, intMix[i%16]) % rows;
            fnvHash(intMix, cache ,parent*hashWords);
        }
        // Flatten the uint32 mix into a binary one and return
        for (uint32 i = 0; i < intMix.length; i++) {
            mix.PutUint32(i*4, intMix[i]);
        }
        return mix.sha3_512();
    }

    function lookup(uint32[] memory cache, uint32 index) pure private returns(uint32[] memory) {
        bytes memory rawData = generateDatasetItem(cache, index);
		uint32[] memory data = new uint32[](rawData.length/4);
		for (uint32 i = 0; i < data.length; i++) {
			data[i] = rawData.Uint32(i*4);
		}
		return data;
	}

    function copy(uint32[] memory dst, uint32 dstOffset, uint32[] memory src, uint32 srcOffset) pure private {
        uint32 dstmin = uint32(dst.length) - dstOffset;
        uint32 srcmin = uint32(src.length) - srcOffset;
        uint32 min = dstmin > srcmin ? srcmin : dstmin;
        for(uint32 i = 0; i < min; i++) {
            dst[dstOffset + i] = src[srcOffset + i];
        }
    }


    // hashimoto aggregates data from the full dataset in order to produce our final
    // value for a particular header hash and nonce.
    function hashimoto(bytes32 hash, uint64 nonce, uint64 size, uint32[] memory cache) pure private returns(bytes32, bytes32) {
        // Calculate the number of theoretical rows (we use one buffer nonetheless)
        uint32 rows = uint32(size) / mixBytes;

        // Combine header+nonce into a 64 byte seed
        bytes memory seed = new bytes(40);
        seed.copyBytes32(0, hash);
        seed.PutUint64(32, nonce);

        seed = seed.sha3_512();
        uint32 seedHead = seed.Uint32(0);

        // Start the mix with replicated seed
        uint32[] memory mix = new uint32[](mixBytes/4);
        for (uint32 i = 0; i < mix.length; i++) {
            mix[i] = seed.Uint32(i%16*4);
        }
        // Mix in random dataset nodes
        uint32[] memory temp = new uint32[](mix.length);

        for (uint32 i = 0; i < loopAccesses; i++) { // Each loop consumes around 4236935 gas.
                                                    // Each loop have 2 keccak512 calculation.
            uint32 parent = fnv(i^seedHead, mix[i%mix.length]) % rows;
            for (uint32 j = 0; j < mixBytes/hashBytes; j++) {
                uint32[] memory data = lookup(cache, 2*parent+j);
                copy(temp, j*hashWords, data, 0);
            }
            fnvHash(mix, temp, 0);
        }

        // Compress mix
        for (uint32 i = 0; i < mix.length; i += 4) {
            mix[i/4] = fnv(fnv(fnv(mix[i], mix[i+1]), mix[i+2]), mix[i+3]);
        }
        //mix = mix[:len(mix)/4];
        uint256 digest = 0;
        for (uint32 i = 0; i < mix.length/4; i++) {
            //binary.LittleEndian.PutUint32(digest[i*4:], val)
            digest <<= 32;
            uint32 val = mix[i];
            digest |= uint256((val&0xff) << 24    |
                      ((val>>8)&0xff) << 16 |
                      ((val>>16)&0xff) << 8 |
                      (val>>24));
        }
        return (bytes32(digest), keccak256(abi.encodePacked(seed, digest)));
    }

    // hashimotoLight aggregates data from the full dataset (using only a small
    // in-memory cache) in order to produce our final value for a particular header
    // hash and nonce.
    function hashimotoLight(uint64 size, uint32[] memory cache, bytes32 hash, uint64 nonce) pure public returns (bytes32, bytes32) {
        return hashimoto(hash, nonce, size, cache);
    }
}