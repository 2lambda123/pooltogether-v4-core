// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.6;
import "../libraries/DrawLib.sol";

interface ITsunamiDrawSettingsHistory {

  /**
    * @notice Emit when a new draw has been created.
    * @param drawId       Draw id
    * @param timestamp    Epoch timestamp when the draw is created.
    * @param winningRandomNumber Randomly generated number used to calculate draw winning numbers
  */
  event DrawSet (
    uint32 drawId,
    uint32 timestamp,
    uint256 winningRandomNumber
  );

  /**
    * @notice Emitted when the DrawParams are set/updated
    * @param drawId       Draw id
    * @param drawSettings DrawLib.TsunamiDrawSettings
  */
  event DrawSettingsSet(uint32 indexed drawId, DrawLib.TsunamiDrawSettings drawSettings);


  /**
    * @notice Read newest DrawSettings from the draws ring buffer.
    * @dev    Uses the nextDrawIndex to calculate the most recently added Draw.
    * @return drawSettings DrawLib.TsunamiDrawSettings
    * @return drawId Draw.drawId
  */
  function getNewestDrawSettings() external view returns (DrawLib.TsunamiDrawSettings memory drawSettings, uint32 drawId);

  /**
    * @notice Read oldest DrawSettings from the draws ring buffer.
    * @dev    Finds the oldest Draw by buffer.nextIndex and buffer.lastDrawId
    * @return drawSettings DrawLib.TsunamiDrawSettings
    * @return drawId Draw.drawId
  */
  function getOldestDrawSettings() external view returns (DrawLib.TsunamiDrawSettings memory drawSettings, uint32 drawId);

  /**
    * @notice Gets array of TsunamiDrawSettingsHistorySettings for Draw.drawID(s)
    * @param drawIds Draw.drawId
   */
  function getDrawSettings(uint32[] calldata drawIds) external view returns (DrawLib.TsunamiDrawSettings[] memory);

  /**
    * @notice Gets the TsunamiDrawSettingsHistorySettings for a Draw.drawID
    * @param drawId Draw.drawId
   */
  function getDrawSetting(uint32 drawId) external view returns (DrawLib.TsunamiDrawSettings memory);

  /**
    * @notice Sets TsunamiDrawSettingsHistorySettings for a Draw.drawID.
    * @dev    Only callable by the owner or manager
    * @param drawId Draw.drawId
    * @param draw   TsunamiDrawSettingsHistorySettings struct
   */
  function pushDrawSettings(uint32 drawId, DrawLib.TsunamiDrawSettings calldata draw) external returns(bool);

  /**
    * @notice Set existing Draw in draws ring buffer with new parameters.
    * @dev    Updating a Draw should be used sparingly and only in the event an incorrect Draw parameter has been stored.
    * @return Draw.drawId
  */
  function setDrawSetting(uint32 drawId, DrawLib.TsunamiDrawSettings calldata draw) external returns(uint32); // maybe return drawIndex
  
}