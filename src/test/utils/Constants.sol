// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

/**
 * @title Constants
 * @notice Mainnet addresses for Yield Basis protocol and related contracts
 */
library Constants {
    // Network

    // Common Addresses
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    
    // DAO
    address constant YB = 0x01791F726B4103694969820be083196cC7c045fF;
    address constant VEYB = 0x8235c179E9e84688FBd8B12295EfC26834dAC211;
    address constant GAUGE_CONTROLLER = 0x1Be14811A3a06F6aF4fA64310a636e1Df04c1c21;
    address constant YB_FACTORY = 0x370a449FeBb9411c95bf897021377fe0B7D100c0;

    // === WBTC Market (0) ===
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant WBTC_AMM = 0xa25306937dbA98378c32F167588F5Dc17A95c94b;
    address constant WBTC_POOL = 0xD9FF8396554A0d18B2CFbeC53e1979b7ecCe8373;
    address constant WBTC_LT = 0x6095a220C5567360d459462A25b1AD5aEAD45204;
    address constant WBTC_STAKER = 0x37f45E64935e7B8383D2f034048B32770B04E8bd;
    address constant WBTC_V_POOL = 0xABf17d1deF75dA1B41B6df5f0b4AecE602b4E045;
    address constant WBTC_PRICE_ORACLE = 0x7Ec34e12A770DfCa068FF287bE9F2799EE70DE24;

    // === cbBTC Market (1) ===
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant CBBTC_AMM = 0xB42e34Bf1f8627189e099ABDB069B9D73B521E4F;
    address constant CBBTC_POOL = 0x83f24023d15d835a213df24fd309c47dAb5BEb32;
    address constant CBBTC_LT = 0xD6a1147666f6E4d7161caf436d9923D44d901112;
    address constant CBBTC_STAKER = 0x3dAe83d236b4Ec301A8d0553f8c13Cb9b7925B6a;
    address constant CBBTC_V_POOL = 0x2dA2Aada1445a5101d648F3c8711B070799bbc91;
    address constant CBBTC_PRICE_ORACLE = 0x3E5A6c61488de85383Fb0efD8c152d3e10C6bfE6;

    // === tBTC Market (2) ===
    address constant TBTC = 0x18084fbA666a33d37592fA2633fD49a74DD93a88;
    address constant TBTC_AMM = 0xb0faaBE84076c6330A9642a6400e87CE4cAec9d4;
    address constant TBTC_POOL = 0xf1F435B05D255a5dBdE37333C0f61DA6F69c6127;
    address constant TBTC_LT = 0x2B513eBe7070Cff91cf699a0BFe5075020C732FF;
    address constant TBTC_STAKER = 0x2a4671fd269dF5B3DA03103c74063dA10D03E23C;
    address constant TBTC_V_POOL = 0xFD1DB6F59fd1FBe0635F3DF11c127B3DDC744092;
    address constant TBTC_PRICE_ORACLE = 0x58321Ba91c7d4BdbCBC2142256b2c42d9eCFc573;
}
