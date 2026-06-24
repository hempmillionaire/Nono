#include "blocks.h"

#include <unordered_map>

extern const unsigned char checkpoints[];
extern const size_t checkpoints_len;
extern const unsigned char stagenet_blocks[];
extern const size_t stagenet_blocks_len;
extern const unsigned char testnet_blocks[];
extern const size_t testnet_blocks_len;

namespace blocks
{

  // NONO ships NO precomputed mainnet block hashes. The fork inherited Monero's
  // src/blocks/checkpoints.dat (Monero mainnet hash-of-hashes, sha256 matches
  // Monero's expected_block_hashes_hash, so load_compiled_in_block_hashes would
  // accept it). Because NONO runs as MAINNET nettype, loading it makes every
  // syncing node fast-sync-validate NONO blocks against Monero's hashes and fail
  // with "usable is negative" in prevalidate_block_hashes, breaking node sync
  // network-wide (the mining node never hits it; only downloading nodes do).
  // NONO is a fresh chain and does not need fast-sync precomputed hashes, so we
  // omit the MAINNET entry entirely; GetCheckpointsData() then returns an empty
  // span and load_compiled_in_block_hashes() skips loading. testnet/stagenet
  // were already empty. To ship real NONO checkpoints later, regenerate
  // checkpoints.dat for NONO and re-add the MAINNET entry with its new hash.
  const std::unordered_map<cryptonote::network_type, const epee::span<const unsigned char>, std::hash<size_t>> CheckpointsByNetwork = {
    {cryptonote::network_type::STAGENET, {stagenet_blocks, stagenet_blocks_len}},
    {cryptonote::network_type::TESTNET, {testnet_blocks, testnet_blocks_len}}
  };

  const epee::span<const unsigned char> GetCheckpointsData(cryptonote::network_type network)
  {
    const auto it = CheckpointsByNetwork.find(network);
    if (it != CheckpointsByNetwork.end())
    {
      return it->second;
    }
    return nullptr;
  }

}
