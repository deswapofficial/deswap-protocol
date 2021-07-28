pragma solidity ^0.5.16;

import "./DBep20Delegate.sol";

interface DawLike {
  function delegate(address delegatee) external;
}

/**
 * @title Deswap's DDaw
 LikeDelegate Contract
 * @notice DTokens which can 'delegate votes' of their underlying BEP-20
 * @author Deswap
 */
contract DDawLikeDelegate is DBep20Delegate {
  /**
   * @notice Construct an empty delegate
   */
  constructor() public DBep20Delegate() {}

  /**
   * @notice Admin call to delegate the votes of the DAW-like underlying
   * @param dawLikeDelegatee The address to delegate votes to
   */
  function _delegateDawLikeTo(address dawLikeDelegatee) external {
    require(msg.sender == admin, "only the admin may set the daw-like delegate");
    DawLike(underlying).delegate(dawLikeDelegatee);
  }
}