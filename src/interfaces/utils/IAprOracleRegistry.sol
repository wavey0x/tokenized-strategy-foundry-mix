pragma solidity ^0.8.20;

interface IAprOracleRegistry {
    event GovernanceTransferred(
        address indexed previousGovernance,
        address indexed newGovernance
    );

    function getCurrentApr(address _vault) external view returns (uint256 apr);

    function getExpectedApr(address _vault, int256 _delta)
        external
        view
        returns (uint256 apr);

    function getStrategyApr(address _strategy, int256 _debtChange)
        external
        view
        returns (uint256 apr);

    function getWeightedAverageApr(address _vault, int256 _delta)
        external
        view
        returns (uint256);

    function governance() external view returns (address);

    function oracles(address) external view returns (address);

    function setOracle(address _strategy, address _oracle) external;

    function transferGovernance(address _newGovernance) external;
}