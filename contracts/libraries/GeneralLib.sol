// SPDX-License-Identifier: MIT

pragma solidity 0.8.10;

import {Helpers} from './Helpers.sol';
import {DataTypes} from './DataTypes.sol';
import {Helpers} from './Helpers.sol';
import {Errors} from './Errors.sol';
import {Events} from './Events.sol';
import {IFollowModule} from '../interfaces/IFollowModule.sol';
import {ICollectModule} from '../interfaces/ICollectModule.sol';
import {IReferenceModule} from '../interfaces/IReferenceModule.sol';

import './Constants.sol';
import {MetaTxHelpers} from './MetaTxHelpers.sol';
import {InteractionHelpers} from './InteractionHelpers.sol';

// TODO: For publishing, increment the pubId here.
/**
 * @title GeneralLib
 * @author Lens Protocol
 *
 * @notice This is the library that contains the logic for profile creation, publication,
 * admin, and governance functionality.
 *
 * @dev The functions are external, so they are called from the hub via `delegateCall` under
 * the hood. Furthermore, expected events are emitted from this library instead of from the
 * hub to alleviate code size concerns.
 *
 * Note: The setDispatcher non-signature function was not migrated as it was more space-efficient
 * to leave it in the hub.
 */
library GeneralLib {
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);

    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /**
     * @notice Sets the governance address.
     *
     * @param newGovernance The new governance address to set.
     */
    function setGovernance(address newGovernance) external {
        address prevGovernance;
        assembly {
            prevGovernance := sload(GOVERNANCE_SLOT)
            sstore(GOVERNANCE_SLOT, newGovernance)
        }
        emit Events.GovernanceSet(msg.sender, prevGovernance, newGovernance, block.timestamp);
    }

    /**
     * @notice Sets the emergency admin address.
     *
     * @param newEmergencyAdmin The new governance address to set.
     */
    function setEmergencyAdmin(address newEmergencyAdmin) external {
        address prevEmergencyAdmin;
        assembly {
            prevEmergencyAdmin := sload(EMERGENCY_ADMIN_SLOT)
            sstore(EMERGENCY_ADMIN_SLOT, newEmergencyAdmin)
        }
        emit Events.EmergencyAdminSet(
            msg.sender,
            prevEmergencyAdmin,
            newEmergencyAdmin,
            block.timestamp
        );
    }

    /**
     * @notice Sets the protocol state.
     *
     * @param newState The new protocol state to set.
     *
     * Note: This does NOT validate the caller, and is only to be used for initialization.
     */
    function setStateSimple(DataTypes.ProtocolState newState) external {
        DataTypes.ProtocolState prevState;
        assembly {
            prevState := sload(PROTOCOL_STATE_SLOT)
            sstore(PROTOCOL_STATE_SLOT, newState)
        }
        emit Events.StateSet(msg.sender, prevState, newState, block.timestamp);
    }

    /**
     * @notice Sets the protocol state and validates the caller. The emergency admin can only
     * pause further (Unpaused => PublishingPaused => Paused). Whereas governance can set any
     * state.
     *
     * @param newState The new protocol state to set.
     */
    function setStateFull(DataTypes.ProtocolState newState) external {
        address emergencyAdmin;
        address governance;
        DataTypes.ProtocolState prevState;
        assembly {
            emergencyAdmin := sload(EMERGENCY_ADMIN_SLOT)
            governance := sload(GOVERNANCE_SLOT)
            prevState := sload(PROTOCOL_STATE_SLOT)
            sstore(PROTOCOL_STATE_SLOT, newState)
        }
        if (msg.sender == emergencyAdmin) {
            if (newState == DataTypes.ProtocolState.Unpaused)
                revert Errors.EmergencyAdminCannotUnpause();
            if (prevState == DataTypes.ProtocolState.Paused) revert Errors.Paused();
        } else if (msg.sender != governance) {
            revert Errors.NotGovernanceOrEmergencyAdmin();
        }
        emit Events.StateSet(msg.sender, prevState, newState, block.timestamp);
    }

    function setDefaultProfile(address wallet, uint256 profileId) external {
        _setDefaultProfile(wallet, profileId);
    }

    /**
     * @notice Executes the logic to create a profile with the given parameters to the given address.
     *
     * @param vars The CreateProfileData struct containing the following parameters:
     *      to: The address receiving the profile.
     *      handle: The handle to set for the profile, must be unique and non-empty.
     *      imageURI: The URI to set for the profile image.
     *      followModule: The follow module to use, can be the zero address.
     *      followModuleInitData: The follow module initialization data, if any
     *      followNFTURI: The URI to set for the follow NFT.
     * @param profileId The profile ID to associate with this profile NFT (token ID).
     */
    function createProfile(DataTypes.CreateProfileData calldata vars, uint256 profileId) external {
        _validateProfileCreatorWhitelisted();
        _validateHandle(vars.handle);

        if (bytes(vars.imageURI).length > MAX_PROFILE_IMAGE_URI_LENGTH)
            revert Errors.ProfileImageURILengthInvalid();

        bytes32 handleHash = keccak256(bytes(vars.handle));

        uint256 resolvedProfileId;
        uint256 handleHashSlot;
        assembly {
            mstore(0, handleHash)
            mstore(32, PROFILE_ID_BY_HANDLE_HASH_MAPPING_SLOT)
            handleHashSlot := keccak256(0, 64)
            resolvedProfileId := sload(handleHashSlot)
        }
        if (resolvedProfileId != 0) revert Errors.HandleTaken();
        assembly {
            sstore(handleHashSlot, profileId)
        }
        _setProfileString(profileId, PROFILE_HANDLE_OFFSET, vars.handle);
        _setProfileString(profileId, PROFILE_IMAGE_URI_OFFSET, vars.imageURI);
        _setProfileString(profileId, PROFILE_FOLLOW_NFT_URI_OFFSET, vars.followNFTURI);

        bytes memory followModuleReturnData;
        if (vars.followModule != address(0)) {
            address followModule = vars.followModule;
            assembly {
                mstore(0, profileId)
                mstore(32, PROFILE_BY_ID_MAPPING_SLOT)
                let slot := add(keccak256(0, 64), PROFILE_FOLLOW_MODULE_OFFSET)
                sstore(slot, followModule)
            }

            followModuleReturnData = _initFollowModule(
                profileId,
                vars.followModule,
                vars.followModuleInitData
            );
        }
        emit Events.ProfileCreated(
            profileId,
            msg.sender, // Creator is always the msg sender
            vars.to,
            vars.handle,
            vars.imageURI,
            vars.followModule,
            followModuleReturnData,
            vars.followNFTURI,
            block.timestamp
        );
    }

    /**
     * @notice Sets the follow module for a given profile.
     *
     * @param profileId The profile ID to set the follow module for.
     * @param followModule The follow module to set for the given profile, if any.
     * @param followModuleInitData The data to pass to the follow module for profile initialization.
     */
    function setFollowModule(
        uint256 profileId,
        address followModule,
        bytes calldata followModuleInitData
    ) external {
        _setFollowModule(profileId, followModule, followModuleInitData);
    }

    function setProfileImageURI(uint256 profileId, string calldata imageURI) external {
        _validateCallerIsProfileOwnerOrDispatcher(profileId);
        _setProfileImageURI(profileId, imageURI);
    }

    function setFollowNFTURI(uint256 profileId, string calldata followNFTURI) external {
        _validateCallerIsProfileOwnerOrDispatcher(profileId);
        _setFollowNFTURI(profileId, followNFTURI);
    }

    function post(DataTypes.PostData calldata vars, uint256 pubId) external {
        _validateCallerIsProfileOwnerOrDispatcher(vars.profileId);
        _createPost(
            vars.profileId,
            pubId,
            vars.contentURI,
            vars.collectModule,
            vars.collectModuleInitData,
            vars.referenceModule,
            vars.referenceModuleInitData
        );
    }

    function comment(DataTypes.CommentData calldata vars, uint256 pubId) external {
        _validateCallerIsProfileOwnerOrDispatcher(vars.profileId);
        _createComment(vars, pubId);
    }

    /**
     * @notice Creates a comment publication mapped to the given profile.
     *
     * @dev This function is unique in that it requires many variables, so, unlike the other publishing functions,
     * we need to pass the full CommentData struct in memory to avoid a stack too deep error.
     *
     * @param vars The CommentData struct to use to create the comment.
     * @param pubId The publication ID to associate with this publication.
     */
    function _createComment(DataTypes.CommentData calldata vars, uint256 pubId) private {
        // Validate existence of the pointed publication
        uint256 profileId = vars.profileId;
        uint256 profileIdPointed = vars.profileIdPointed;
        uint256 pubIdPointed = vars.pubIdPointed;
        uint256 pubCountPointed;
        assembly {
            mstore(0, profileIdPointed)
            mstore(32, PROFILE_BY_ID_MAPPING_SLOT)
            // pubCount is at offset 0, so we don't need to add anything.
            let slot := keccak256(0, 64)
            pubCountPointed := sload(slot)
        }

        if (pubCountPointed < pubIdPointed || pubIdPointed == 0)
            revert Errors.PublicationDoesNotExist();

        // Ensure the pointed publication is not the comment being created
        if (profileId == profileIdPointed && pubIdPointed == pubId)
            revert Errors.CannotCommentOnSelf();

        assembly {
            mstore(0, profileId)
            mstore(32, PUB_BY_ID_BY_PROFILE_MAPPING_SLOT)
            mstore(32, keccak256(0, 64))
            mstore(0, pubId)
            // profile ID pointed is at offset 0, so we don't need to add anything.
            let slot := keccak256(0, 64)
            sstore(slot, profileIdPointed)
            slot := add(slot, PUBLICATION_PUB_ID_POINTED_OFFSET)
            sstore(slot, pubIdPointed)
        }
        _setPublicationContentURI(vars.profileId, pubId, vars.contentURI);

        // Collect Module Initialization
        bytes memory collectModuleReturnData = _initPubCollectModule(
            vars.profileId,
            pubId,
            vars.collectModule,
            vars.collectModuleInitData
        );

        // Reference module initialization
        bytes memory referenceModuleReturnData = _initPubReferenceModule(
            vars.profileId,
            pubId,
            vars.referenceModule,
            vars.referenceModuleInitData
        );

        // Reference module validation
        address referenceModulePointed;
        assembly {
            mstore(0, profileIdPointed)
            mstore(32, PUB_BY_ID_BY_PROFILE_MAPPING_SLOT)
            mstore(32, keccak256(0, 64))
            mstore(0, pubIdPointed)
            let slot := add(keccak256(0, 64), PUBLICATION_REFERENCE_MODULE_OFFSET)
            referenceModulePointed := sload(slot)
        }
        if (referenceModulePointed != address(0)) {
            IReferenceModule(referenceModulePointed).processComment(
                vars.profileId,
                vars.profileIdPointed,
                vars.pubIdPointed,
                vars.referenceModuleData
            );
        }

        emit Events.CommentCreated(
            vars.profileId,
            pubId,
            vars.contentURI,
            vars.profileIdPointed,
            vars.pubIdPointed,
            vars.referenceModuleData,
            vars.collectModule,
            collectModuleReturnData,
            vars.referenceModule,
            referenceModuleReturnData,
            block.timestamp
        );
        // Prevents a stack too deep error
        // _emitCommentCreated(vars, pubId, collectModuleReturnData, referenceModuleReturnData);
    }

    function _createCommentWithSigStruct(DataTypes.CommentWithSigData calldata vars, uint256 pubId)
        private
    {
        // Validate existence of the pointed publication
        uint256 profileId = vars.profileId;
        uint256 profileIdPointed = vars.profileIdPointed;
        uint256 pubIdPointed = vars.pubIdPointed;
        uint256 pubCountPointed;
        assembly {
            mstore(0, profileIdPointed)
            mstore(32, PROFILE_BY_ID_MAPPING_SLOT)
            // pubCount is at offset 0, so we don't need to add anything.
            let slot := keccak256(0, 64)
            pubCountPointed := sload(slot)
        }

        if (pubCountPointed < pubIdPointed || pubIdPointed == 0)
            revert Errors.PublicationDoesNotExist();

        // Ensure the pointed publication is not the comment being created
        if (profileId == profileIdPointed && pubIdPointed == pubId)
            revert Errors.CannotCommentOnSelf();

        assembly {
            mstore(0, profileId)
            mstore(32, PUB_BY_ID_BY_PROFILE_MAPPING_SLOT)
            mstore(32, keccak256(0, 64))
            mstore(0, pubId)
            // profile ID pointed is at offset 0, so we don't need to add anything.
            let slot := keccak256(0, 64)
            sstore(slot, profileIdPointed)
            slot := add(slot, PUBLICATION_PUB_ID_POINTED_OFFSET)
            sstore(slot, pubIdPointed)
        }
        _setPublicationContentURI(vars.profileId, pubId, vars.contentURI);

        // Collect Module Initialization
        bytes memory collectModuleReturnData = _initPubCollectModule(
            vars.profileId,
            pubId,
            vars.collectModule,
            vars.collectModuleInitData
        );

        // Reference module initialization
        bytes memory referenceModuleReturnData = _initPubReferenceModule(
            vars.profileId,
            pubId,
            vars.referenceModule,
            vars.referenceModuleInitData
        );

        // Reference module validation
        address referenceModulePointed;
        assembly {
            mstore(0, profileIdPointed)
            mstore(32, PUB_BY_ID_BY_PROFILE_MAPPING_SLOT)
            mstore(32, keccak256(0, 64))
            mstore(0, pubIdPointed)
            let slot := add(keccak256(0, 64), PUBLICATION_REFERENCE_MODULE_OFFSET)
            referenceModulePointed := sload(slot)
        }
        if (referenceModulePointed != address(0)) {
            IReferenceModule(referenceModulePointed).processComment(
                vars.profileId,
                vars.profileIdPointed,
                vars.pubIdPointed,
                vars.referenceModuleData
            );
        }

        emit Events.CommentCreated(
            vars.profileId,
            pubId,
            vars.contentURI,
            vars.profileIdPointed,
            vars.pubIdPointed,
            vars.referenceModuleData,
            vars.collectModule,
            collectModuleReturnData,
            vars.referenceModule,
            referenceModuleReturnData,
            block.timestamp
        );
    }

    /**
     * @notice Creates a mirror publication mapped to the given profile.
     *
     * @param vars The MirrorData struct to use to create the mirror.
     * @param pubId The publication ID to associate with this publication.
     * @param _pubByIdByProfile The storage reference to the mapping of publications by publication ID by profile ID.
     * param _referenceModuleWhitelisted The storage reference to the mapping of whitelist status by reference module address.
     */
    function createMirror(
        DataTypes.MirrorData memory vars,
        uint256 pubId,
        mapping(uint256 => mapping(uint256 => DataTypes.PublicationStruct))
            storage _pubByIdByProfile
    ) external {
        (uint256 rootProfileIdPointed, uint256 rootPubIdPointed, ) = Helpers.getPointedIfMirror(
            vars.profileIdPointed,
            vars.pubIdPointed,
            _pubByIdByProfile
        );

        _pubByIdByProfile[vars.profileId][pubId].profileIdPointed = rootProfileIdPointed;
        _pubByIdByProfile[vars.profileId][pubId].pubIdPointed = rootPubIdPointed;

        // Reference module initialization
        bytes memory referenceModuleReturnData = _initPubReferenceModule(
            vars.profileId,
            pubId,
            vars.referenceModule,
            vars.referenceModuleInitData
        );

        // Reference module validation
        address refModule = _pubByIdByProfile[rootProfileIdPointed][rootPubIdPointed]
            .referenceModule;
        if (refModule != address(0)) {
            IReferenceModule(refModule).processMirror(
                vars.profileId,
                rootProfileIdPointed,
                rootPubIdPointed,
                vars.referenceModuleData
            );
        }

        emit Events.MirrorCreated(
            vars.profileId,
            pubId,
            rootProfileIdPointed,
            rootPubIdPointed,
            vars.referenceModuleData,
            vars.referenceModule,
            referenceModuleReturnData,
            block.timestamp
        );
    }

    /**
     * @notice Follows the given profiles, executing the necessary logic and module calls before minting the follow
     * NFT(s) to the follower.
     *
     * @param follower The address executing the follow.
     * @param profileIds The array of profile token IDs to follow.
     * @param followModuleDatas The array of follow module data parameters to pass to each profile's follow module.
     * @param _profileById A pointer to the storage mapping of profile structs by profile ID.
     * @param _profileIdByHandleHash A pointer to the storage mapping of profile IDs by handle hash.
     *
     * @return uint256[] An array of integers representing the minted follow NFTs token IDs.
     */
    function follow(
        address follower,
        uint256[] calldata profileIds,
        bytes[] calldata followModuleDatas,
        mapping(uint256 => DataTypes.ProfileStruct) storage _profileById,
        mapping(bytes32 => uint256) storage _profileIdByHandleHash
    ) external returns (uint256[] memory) {
        return
            InteractionHelpers.follow(
                follower,
                profileIds,
                followModuleDatas,
                _profileById,
                _profileIdByHandleHash
            );
    }

    /**
     * @notice Collects the given publication, executing the necessary logic and module call before minting the
     * collect NFT to the collector.
     *
     * @param collector The address executing the collect.
     * @param profileId The token ID of the publication being collected's parent profile.
     * @param pubId The publication ID of the publication being collected.
     * @param collectModuleData The data to pass to the publication's collect module.
     * @param collectNFTImpl The address of the collect NFT implementation, which has to be passed because it's an immutable in the hub.
     * @param _pubByIdByProfile A pointer to the storage mapping of publications by pubId by profile ID.
     * @param _profileById A pointer to the storage mapping of profile structs by profile ID.
     *
     * @return uint256 An integer representing the minted token ID.
     */
    function collect(
        address collector,
        uint256 profileId,
        uint256 pubId,
        bytes calldata collectModuleData,
        address collectNFTImpl,
        mapping(uint256 => mapping(uint256 => DataTypes.PublicationStruct))
            storage _pubByIdByProfile,
        mapping(uint256 => DataTypes.ProfileStruct) storage _profileById
    ) external returns (uint256) {
        return
            InteractionHelpers.collect(
                collector,
                profileId,
                pubId,
                collectModuleData,
                collectNFTImpl,
                _pubByIdByProfile,
                _profileById
            );
    }

    /**
     * @notice Validates parameters and increments the nonce for a given owner using the `permit()`
     * function. Note that we can use the unsafeOwnerOf function since `basePermit` reverts upon
     * receiving a zero address from an `ecrecover`.
     *
     * @param spender The spender to approve.
     * @param tokenId The token ID to approve the spender for.
     * @param sig the EIP712Signature struct containing the token owner's signature.
     */
    function permit(
        address spender,
        uint256 tokenId,
        DataTypes.EIP712Signature calldata sig
    ) external {
        MetaTxHelpers.basePermit(spender, tokenId, sig);
        assembly {
            mstore(0, tokenId)
            mstore(32, TOKEN_APPROVAL_MAPPING_SLOT)
            let slot := keccak256(0, 64)
            sstore(slot, spender)
        }
        emit Approval(Helpers.unsafeOwnerOf(tokenId), spender, tokenId);
    }

    /**
     * @notice Validates parameters and increments the nonce for a given owner using the `permitForAll()`
     * function.
     *
     * @param owner The owner to approve the operator for, this is the signer.
     * @param operator The operator to approve for the owner.
     * @param approved Whether or not the operator should be approved.
     * @param sig the EIP712Signature struct containing the token owner's signature.
     */
    function permitForAll(
        address owner,
        address operator,
        bool approved,
        DataTypes.EIP712Signature calldata sig
    ) external {
        MetaTxHelpers.basePermitForAll(owner, operator, approved, sig);
        assembly {
            mstore(0, owner)
            mstore(32, OPERATOR_APPROVAL_MAPPING_SLOT)
            mstore(32, keccak256(0, 64))
            mstore(0, operator)
            let slot := keccak256(0, 64)
            sstore(slot, approved)
        }
        emit ApprovalForAll(owner, operator, approved);
    }

    /**
     * @notice Sets the default profile via signature for a given owner.
     *
     * @param vars the SetDefaultProfileWithSigData struct containing the relevant parameters.
     */
    function setDefaultProfileWithSig(DataTypes.SetDefaultProfileWithSigData calldata vars)
        external
    {
        MetaTxHelpers.baseSetDefaultProfileWithSig(vars);
        _setDefaultProfile(vars.wallet, vars.profileId);
    }

    /**
     * @notice sets the follow module via signature for a given profile.
     *
     * @param vars the SetFollowModuleWithSigData struct containing the relevant parameters.
     */
    function setFollowModuleWithSig(DataTypes.SetFollowModuleWithSigData calldata vars) external {
        MetaTxHelpers.baseSetFollowModuleWithSig(vars);
        _setFollowModule(vars.profileId, vars.followModule, vars.followModuleInitData);
    }

    /**
     * @notice Sets the dispatcher via signature for a given profile.
     *
     * @param vars the setDispatcherWithSigData struct containing the relevant parameters.
     */
    function setDispatcherWithSig(DataTypes.SetDispatcherWithSigData calldata vars) external {
        MetaTxHelpers.baseSetDispatcherWithSig(vars);
        uint256 profileId = vars.profileId;
        address dispatcher = vars.dispatcher;
        assembly {
            mstore(0, profileId)
            mstore(32, DISPATCHER_BY_PROFILE_MAPPING_SLOT)
            let slot := keccak256(0, 64)
            sstore(slot, dispatcher)
        }
        emit Events.DispatcherSet(profileId, dispatcher, block.timestamp);
    }

    /**
     * @notice Sets the profile image URI via signature for a given profile.
     *
     * @param vars the SetProfileImageURIWithSigData struct containing the relevant parameters.
     */
    function setProfileImageURIWithSig(DataTypes.SetProfileImageURIWithSigData calldata vars)
        external
    {
        MetaTxHelpers.baseSetProfileImageURIWithSig(vars);
        _setProfileImageURI(vars.profileId, vars.imageURI);
    }

    /**
     * @notice Sets the follow NFT URI via signature for a given profile.
     *
     * @param vars the SetFollowNFTURIWithSigData struct containing the relevant parameters.
     */
    function setFollowNFTURIWithSig(DataTypes.SetFollowNFTURIWithSigData calldata vars) external {
        MetaTxHelpers.baseSetFollowNFTURIWithSig(vars);
        _setFollowNFTURI(vars.profileId, vars.followNFTURI);
    }

    /**
     * @notice Validates parameters and increments the nonce for a given owner using the
     * `postWithSig()` function.
     *
     * @param vars the PostWithSigData struct containing the relevant parameters.
     */
    function postWithSig(DataTypes.PostWithSigData calldata vars, uint256 pubId) external {
        MetaTxHelpers.basePostWithSig(vars);
        _createPost(
            vars.profileId,
            pubId,
            vars.contentURI,
            vars.collectModule,
            vars.collectModuleInitData,
            vars.referenceModule,
            vars.referenceModuleInitData
        );
    }

    /**
     * @notice Validates parameters and increments the nonce for a given owner using the
     * `commentWithSig()` function.
     *
     * @param vars the CommentWithSig struct containing the relevant parameters.
     */
    function commentWithSig(DataTypes.CommentWithSigData calldata vars, uint256 pubId) external {
        MetaTxHelpers.baseCommentWithSig(vars);
        _createCommentWithSigStruct(
            vars,
            // DataTypes.CommentData(
            // vars.profileId,
            // vars.contentURI,
            // vars.profileIdPointed,
            // vars.pubIdPointed,
            // vars.referenceModuleData,
            // vars.collectModule,
            // vars.collectModuleInitData,
            // vars.referenceModule,
            // vars.referenceModuleInitData
            // ),
            pubId
        );
    }

    // uint256 profileId;
    // string contentURI;
    // uint256 profileIdPointed;
    // uint256 pubIdPointed;
    // bytes referenceModuleData;
    // address collectModule;
    // bytes collectModuleInitData;
    // address referenceModule;
    // bytes referenceModuleInitData;

    /**
     * @notice Validates parameters and increments the nonce for a given owner using the
     * `mirrorWithSig()` function.
     *
     * @param vars the MirrorWithSigData struct containing the relevant parameters.
     */
    function mirrorWithSig(DataTypes.MirrorWithSigData calldata vars) external {
        MetaTxHelpers.baseMirrorWithSig(vars);
        // create mirror
    }

    /**
     * @notice Validates parameters and increments the nonce for a given owner using the
     * `burnWithSig()` function.
     *
     * @param tokenId The token ID to burn.
     * @param sig the EIP712Signature struct containing the token owner's signature.
     */
    function burnWithSig(uint256 tokenId, DataTypes.EIP712Signature calldata sig) external {
        MetaTxHelpers.baseBurnWithSig(tokenId, sig);
        // burn profile
    }

    /**
     * @notice Validates parameters and increments the nonce for a given owner using the
     * `followWithSig()` function.
     *
     * @param vars the FollowWithSigData struct containing the relevant parameters.
     */
    function followWithSig(
        DataTypes.FollowWithSigData calldata vars,
        mapping(uint256 => DataTypes.ProfileStruct) storage _profileById,
        mapping(bytes32 => uint256) storage _profileIdByHandleHash
    ) external returns (uint256[] memory) {
        MetaTxHelpers.baseFollowWithSig(vars);
        return
            InteractionHelpers.follow(
                vars.follower,
                vars.profileIds,
                vars.datas,
                _profileById,
                _profileIdByHandleHash
            );
    }

    /**
     * @notice Validates parameters and increments the nonce for a given owner using the
     * `collectWithSig()` function.
     *
     * @param vars the CollectWithSigData struct containing the relevant parameters.
     */
    function collectWithSig(
        DataTypes.CollectWithSigData calldata vars,
        address collectNFTImpl,
        mapping(uint256 => mapping(uint256 => DataTypes.PublicationStruct))
            storage _pubByIdByProfile,
        mapping(uint256 => DataTypes.ProfileStruct) storage _profileById
    ) external returns (uint256) {
        MetaTxHelpers.baseCollectWithSig(vars);
        return
            InteractionHelpers.collect(
                vars.collector,
                vars.profileId,
                vars.pubId,
                vars.data,
                collectNFTImpl,
                _pubByIdByProfile,
                _profileById
            );
    }

    /**
     * @notice Returns the domain separator.
     *
     * @return bytes32 The domain separator.
     */
    function getDomainSeparator() external view returns (bytes32) {
        return MetaTxHelpers.getDomainSeparator();
    }

    function _setDefaultProfile(address wallet, uint256 profileId) private {
        if (profileId > 0 && wallet != Helpers.unsafeOwnerOf(profileId))
            revert Errors.NotProfileOwner();
        assembly {
            mstore(0, wallet)
            mstore(32, DEFAULT_PROFILE_MAPPING_SLOT)
            let slot := keccak256(0, 64)
            sstore(slot, profileId)
        }
        emit Events.DefaultProfileSet(wallet, profileId, block.timestamp);
    }

    function _setFollowModule(
        uint256 profileId,
        address followModule,
        bytes calldata followModuleInitData
    ) private {
        address currentFollowModule;
        uint256 slot;
        assembly {
            mstore(0, profileId)
            mstore(32, PROFILE_BY_ID_MAPPING_SLOT)
            slot := add(keccak256(0, 64), PROFILE_FOLLOW_MODULE_OFFSET)
            currentFollowModule := sload(slot)
        }

        if (followModule != currentFollowModule) {
            assembly {
                sstore(slot, followModule)
            }
        }

        bytes memory followModuleReturnData;
        if (followModule != address(0))
            followModuleReturnData = _initFollowModule(
                profileId,
                followModule,
                followModuleInitData
            );
        emit Events.FollowModuleSet(
            profileId,
            followModule,
            followModuleReturnData,
            block.timestamp
        );
    }

    function _setProfileImageURI(uint256 profileId, string calldata imageURI) private {
        if (bytes(imageURI).length > MAX_PROFILE_IMAGE_URI_LENGTH)
            revert Errors.ProfileImageURILengthInvalid();
        _setProfileString(profileId, PROFILE_IMAGE_URI_OFFSET, imageURI);
        emit Events.ProfileImageURISet(profileId, imageURI, block.timestamp);
    }

    function _setFollowNFTURI(uint256 profileId, string calldata followNFTURI) private {
        _setProfileString(profileId, PROFILE_FOLLOW_NFT_URI_OFFSET, followNFTURI);
        emit Events.FollowNFTURISet(profileId, followNFTURI, block.timestamp);
    }

    function _setProfileString(
        uint256 profileId,
        uint256 profileOffset,
        string calldata value
    ) private {
        assembly {
            let length := value.length
            let cdOffset := value.offset
            mstore(0, profileId)
            mstore(32, PROFILE_BY_ID_MAPPING_SLOT)
            let slot := add(keccak256(0, 64), profileOffset)

            // If the length is greater than 31, storage rules are different.
            switch gt(length, 31)
            case 1 {
                // The length is > 31, so we need to store the actual string in a new slot,
                // equivalent to keccak256(startSlot), and store length*2+1 in startSlot.
                sstore(slot, add(shl(1, length), 1))

                // Calculate the amount of storage slots we need to store the full string.
                // This is equivalent to (string.length + 31)/32.
                let totalStorageSlots := shr(5, add(length, 31))

                // Compute the slot where the actual string will begin, which is the keccak256
                // hash of the slot where we stored the modified length.
                mstore(0, slot)
                slot := keccak256(0, 32)

                // Write the actual string to storage starting at the computed slot.
                // prettier-ignore
                for { let i := 0 } lt(i, totalStorageSlots) { i := add(i, 1) } {
                    sstore(add(slot, i), calldataload(add(cdOffset, mul(32, i))))
                }
            }
            default {
                // The length is greater than 31 so store the string and the length*2
                // in the same slot
                sstore(slot, or(and(calldataload(cdOffset), not(255)), shl(1, length)))
            }
        }
    }

    function _setPublicationContentURI(
        uint256 profileId,
        uint256 pubId,
        string calldata value
    ) private {
        assembly {
            let length := value.length
            let cdOffset := value.offset
            mstore(0, profileId)
            mstore(32, PUB_BY_ID_BY_PROFILE_MAPPING_SLOT)
            mstore(32, keccak256(0, 64))
            mstore(0, pubId)
            let slot := add(keccak256(0, 64), PUBLICATION_CONTENT_URI_OFFSET)

            // If the length is greater than 31, storage rules are different.
            switch gt(length, 31)
            case 1 {
                // The length is > 31, so we need to store the actual string in a new slot,
                // equivalent to keccak256(startSlot), and store length*2+1 in startSlot.
                sstore(slot, add(shl(1, length), 1))

                // Calculate the amount of storage slots we need to store the full string.
                // This is equivalent to (string.length + 31)/32.
                let totalStorageSlots := shr(5, add(length, 31))

                // Compute the slot where the actual string will begin, which is the keccak256
                // hash of the slot where we stored the modified length.
                mstore(0, slot)
                slot := keccak256(0, 32)

                // Write the actual string to storage starting at the computed slot.
                // prettier-ignore
                for { let i := 0 } lt(i, totalStorageSlots) { i := add(i, 1) } {
                    sstore(add(slot, i), calldataload(add(cdOffset, mul(32, i))))
                }
            }
            default {
                // The length is greater than 31 so store the string and the length*2
                // in the same slot
                sstore(slot, or(and(calldataload(cdOffset), not(255)), shl(1, length)))
            }
        }
    }

    /**
     * @notice Creates a post publication mapped to the given profile.
     *
     * @param profileId The profile ID to associate this publication to.
     * @param pubId The publication ID to associate with this publication.
     * @param contentURI The URI to set for this publication.
     * @param collectModule The collect module to set for this publication.
     * @param collectModuleInitData The data to pass to the collect module for publication initialization.
     * @param referenceModule The reference module to set for this publication, if any.
     * @param referenceModuleInitData The data to pass to the reference module for publication initialization.
     */
    function _createPost(
        uint256 profileId,
        uint256 pubId,
        string calldata contentURI,
        address collectModule,
        bytes calldata collectModuleInitData,
        address referenceModule,
        bytes calldata referenceModuleInitData
    ) private {
        _validateCallerIsProfileOwnerOrDispatcher(profileId);
        _setPublicationContentURI(profileId, pubId, contentURI);

        bytes memory collectModuleReturnData = _initPubCollectModule(
            profileId,
            pubId,
            collectModule,
            collectModuleInitData
        );

        // Reference module initialization
        bytes memory referenceModuleReturnData = _initPubReferenceModule(
            profileId,
            pubId,
            referenceModule,
            referenceModuleInitData
        );

        emit Events.PostCreated(
            profileId,
            pubId,
            contentURI,
            collectModule,
            collectModuleReturnData,
            referenceModule,
            referenceModuleReturnData,
            block.timestamp
        );
    }

    function _initFollowModule(
        uint256 profileId,
        address followModule,
        bytes memory followModuleInitData
    ) private returns (bytes memory) {
        _validateFollowModuleWhitelisted(followModule);
        return IFollowModule(followModule).initializeFollowModule(profileId, followModuleInitData);
    }

    function _initPubCollectModule(
        uint256 profileId,
        uint256 pubId,
        address collectModule,
        bytes memory collectModuleInitData //,
    ) private returns (bytes memory) {
        _validateCollectModuleWhitelisted(collectModule);
        assembly {
            mstore(0, profileId)
            mstore(32, PUB_BY_ID_BY_PROFILE_MAPPING_SLOT)
            mstore(32, keccak256(0, 64))
            mstore(0, pubId)
            let slot := add(keccak256(0, 64), PUBLICATION_COLLECT_MODULE_OFFSET)
            sstore(slot, collectModule)
        }
        // _pubByIdByProfile[profileId][pubId].collectModule = collectModule;
        return
            ICollectModule(collectModule).initializePublicationCollectModule(
                profileId,
                pubId,
                collectModuleInitData
            );
    }

    function _initPubReferenceModule(
        uint256 profileId,
        uint256 pubId,
        address referenceModule,
        bytes memory referenceModuleInitData
    ) private returns (bytes memory) {
        if (referenceModule == address(0)) return new bytes(0);
        _validateReferenceModuleWhitelisted(referenceModule);
        assembly {
            mstore(0, profileId)
            mstore(32, PUB_BY_ID_BY_PROFILE_MAPPING_SLOT)
            mstore(32, keccak256(0, 64))
            mstore(0, pubId)
            let slot := add(keccak256(0, 64), PUBLICATION_REFERENCE_MODULE_OFFSET)
            sstore(slot, referenceModule)
        }
        return
            IReferenceModule(referenceModule).initializeReferenceModule(
                profileId,
                pubId,
                referenceModuleInitData
            );
    }

    function _validateCallerIsProfileOwnerOrDispatcher(uint256 profileId) internal view {
        if (msg.sender == Helpers.unsafeOwnerOf(profileId)) {
            return;
        } else {
            address dispatcher;
            assembly {
                mstore(0, profileId)
                mstore(32, DISPATCHER_BY_PROFILE_MAPPING_SLOT)
                let slot := keccak256(0, 64)
                dispatcher := sload(slot)
            }
            if (msg.sender != dispatcher) revert Errors.NotProfileOwnerOrDispatcher();
        }
        // revert Errors.NotProfileOwnerOrDispatcher();
    }

    function _validateProfileCreatorWhitelisted() private view {
        bool whitelisted;
        assembly {
            mstore(0, caller())
            mstore(32, PROFILE_CREATOR_WHITELIST_MAPPING_SLOT)
            let slot := keccak256(0, 64)
            whitelisted := sload(slot)
        }
        if (!whitelisted) revert Errors.ProfileCreatorNotWhitelisted();
    }

    function _validateFollowModuleWhitelisted(address followModule) private view {
        bool whitelist;
        assembly {
            mstore(0, followModule)
            mstore(32, FOLLOW_MODULE_WHITELIST_MAPPING_SLOT)
            let slot := keccak256(0, 64)
            whitelist := sload(slot)
        }
        if (!whitelist) revert Errors.FollowModuleNotWhitelisted();
    }

    function _validateCollectModuleWhitelisted(address collectModule) private view {
        bool whitelisted;
        assembly {
            mstore(0, collectModule)
            mstore(32, COLLECT_MODULE_WHITELIST_MAPPING_SLOT)
            let slot := keccak256(0, 64)
            whitelisted := sload(slot)
        }
        if (!whitelisted) revert Errors.CollectModuleNotWhitelisted();
    }

    function _validateReferenceModuleWhitelisted(address referenceModule) private view {
        bool whitelisted;
        assembly {
            mstore(0, referenceModule)
            mstore(32, REFERENCE_MODULE_WHITELIST_MAPPING_SLOT)
            let slot := keccak256(0, 64)
            whitelisted := sload(slot)
        }
        if (!whitelisted) revert Errors.ReferenceModuleNotWhitelisted();
    }

    function _validateHandle(string calldata handle) private pure {
        bytes memory byteHandle = bytes(handle);
        if (byteHandle.length == 0 || byteHandle.length > MAX_HANDLE_LENGTH)
            revert Errors.HandleLengthInvalid();

        uint256 byteHandleLength = byteHandle.length;
        for (uint256 i = 0; i < byteHandleLength; ) {
            if (
                (byteHandle[i] < '0' ||
                    byteHandle[i] > 'z' ||
                    (byteHandle[i] > '9' && byteHandle[i] < 'a')) &&
                byteHandle[i] != '.' &&
                byteHandle[i] != '-' &&
                byteHandle[i] != '_'
            ) revert Errors.HandleContainsInvalidCharacters();
            unchecked {
                ++i;
            }
        }
    }
}