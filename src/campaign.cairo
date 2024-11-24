use starknet::ContractAddress;
use tokengiver::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};

#[starknet::contract]
mod TokengiverCampaign {
    // *************************************************************************
    //                            IMPORT
    // *************************************************************************
    use super::{ContractAddress, IERC20Dispatcher, IERC20DispatcherTrait};
    use core::traits::TryInto;
    use starknet::get_caller_address;
    use tokengiver::interfaces::ITokenGiverNft::{
        ITokenGiverNftDispatcher, ITokenGiverNftDispatcherTrait
    };
    use tokengiver::interfaces::IRegistry::{
        IRegistryDispatcher, IRegistryDispatcherTrait, IRegistryLibraryDispatcher
    };
    use tokengiver::interfaces::IERC721::{IERC721Dispatcher, IERC721DispatcherTrait};
    use tokengiver::interfaces::ICampaign::ICampaign;
    use tokengiver::base::types::Campaign;
    use tokengiver::base::errors::Errors::{NOT_CAMPAIGN_OWNER, INSUFFICIENT_BALANCE};


    // *************************************************************************
    //                              STORAGE
    // *************************************************************************

    #[storage]
    struct Storage {
        campaign: LegacyMap<ContractAddress, Campaign>,
        campaigns: LegacyMap<u16, ContractAddress>,
        withdrawal_balance: LegacyMap<ContractAddress, u256>,
        count: u16,
        donations: LegacyMap<ContractAddress, u256>,
        donation_count: LegacyMap<ContractAddress, u16>,
        token: IERC20Dispatcher,
        owner: ContractAddress,
    }

    // *************************************************************************
    //                            EVENT
    // *************************************************************************
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        CreateCampaign: CreateCampaign,
        Withdrawal: Withdrawal,
        Donation: Donation
    }

    #[derive(Drop, starknet::Event)]
    struct CreateCampaign {
        #[key]
        owner: ContractAddress,
        #[key]
        campaign_address: ContractAddress,
        token_id: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct Withdrawal {
        #[key]
        campaign_address: ContractAddress,
        #[key]
        recipient: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct Donation {
        #[key]
        campaign_address: ContractAddress,
        #[key]
        donor: ContractAddress,
        token_address: ContractAddress,
        amount: u256,
    }

    // #[constructor]
    // fn constructor(
    //     ref self: ContractState, token_address: ContractAddress, owner: ContractAddress,
    // ) {
    //     self.token.write(IERC20Dispatcher { contract_address: token_address });
    //     self.owner.write(owner);
    // }

    // *************************************************************************
    //                            EXTERNAL FUNCTIONS
    // *************************************************************************

    #[external(v0)]
    impl CampaignImpl of ICampaign<ContractState> {
        fn create_campaign(
            ref self: ContractState,
            token_giverNft_contract_address: ContractAddress,
            registry_hash: felt252,
            implementation_hash: felt252,
            salt: felt252,
            recipient: ContractAddress
        ) -> ContractAddress {
            let count: u16 = self.count.read() + 1;

            // Mint NFT to recipient
            ITokenGiverNftDispatcher { contract_address: token_giverNft_contract_address }
                .mint_token_giver_nft(recipient);

            // Get token ID
            let token_id = ITokenGiverNftDispatcher {
                contract_address: token_giverNft_contract_address
            }
                .get_user_token_id(recipient);

            // Create campaign account
            let campaign_address: ContractAddress = IRegistryLibraryDispatcher {
                class_hash: registry_hash.try_into().unwrap()
            }
                .create_account(
                    implementation_hash, token_giverNft_contract_address, token_id, salt
                );

            // Create and store new campaign
            let new_campaign = Campaign {
                campaign_address, campaign_owner: recipient, metadata_URI: "",
            };

            self.campaign.write(campaign_address, new_campaign);
            self.campaigns.write(count, campaign_address);
            self.count.write(count);

            self.emit(CreateCampaign { owner: recipient, campaign_address, token_id });
            campaign_address
        }

        /// @notice set campaign metadata_uri (`banner_image, description, campaign_image` to be
        /// uploaded to arweave or ipfs)
        /// @params campaign_address the targeted campaign address
        /// @params metadata_uri the campaign CID
        fn set_campaign_metadata_uri(
            ref self: ContractState, campaign_address: ContractAddress, metadata_uri: ByteArray
        ) {
            let mut campaign: Campaign = self.campaign.read(campaign_address);
            assert(get_caller_address() == campaign.campaign_owner, NOT_CAMPAIGN_OWNER);
            campaign.metadata_URI = metadata_uri;
            self.campaign.write(campaign_address, campaign);
        }

        fn set_donation_count(ref self: ContractState, campaign_address: ContractAddress) {
            let prev_count: u16 = self.donation_count.read(campaign_address);
            self.donation_count.write(campaign_address, prev_count + 1);
        }

        fn set_donations(ref self: ContractState, campaign_address: ContractAddress, amount: u256) {
            self.donations.write(campaign_address, amount);
        }

        fn set_available_withdrawal(
            ref self: ContractState, campaign_address: ContractAddress, amount: u256
        ) {
            self.withdrawal_balance.write(campaign_address, amount);
        }

        fn withdraw(ref self: ContractState, campaign_address: ContractAddress, amount: u256) {
            let campaign: Campaign = self.campaign.read(campaign_address);
            let caller: ContractAddress = get_caller_address();

            assert(caller == campaign.campaign_owner, NOT_CAMPAIGN_OWNER);

            let available_balance: u256 = self.withdrawal_balance.read(campaign_address);
            assert(amount <= available_balance, INSUFFICIENT_BALANCE);

            self.withdrawal_balance.write(campaign_address, available_balance - amount);

            // Transfer tokens
            self.token.read().transfer_from(campaign_address, caller, amount);
            self.emit(Withdrawal { campaign_address, recipient: caller, amount });
        }

        fn donate(
            ref self: ContractState,
            campaign_address: ContractAddress,
            token_address: ContractAddress,
            amount: u256
        ) {
            let caller: ContractAddress = get_caller_address();

            IERC20Dispatcher { contract_address: token_address }
                .transfer_from(caller, campaign_address, amount);

            let prev_count: u16 = self.donation_count.read(campaign_address);
            self.donation_count.write(campaign_address, prev_count + 1);

            let prev_donations: u256 = self.donations.read(campaign_address);
            self.donations.write(campaign_address, prev_donations + amount);

            let prev_withdrawal_balance: u256 = self.withdrawal_balance.read(campaign_address);
            self.withdrawal_balance.write(campaign_address, prev_withdrawal_balance + amount);

            self.emit(Donation { campaign_address, donor: caller, token_address, amount });
        }

        // *************************************************************************
        //                            GETTERS
        // *************************************************************************
        fn get_donations(self: @ContractState, campaign_address: ContractAddress) -> u256 {
            self.donations.read(campaign_address)
        }

        fn get_available_withdrawal(
            self: @ContractState, campaign_address: ContractAddress
        ) -> u256 {
            self.withdrawal_balance.read(campaign_address)
        }

        // @notice returns the campaign struct of a campaign address
        // @params campaign_address the targeted campaign address
        fn get_campaign(self: @ContractState, campaign_address: ContractAddress) -> Campaign {
            self.campaign.read(campaign_address)
        }

        fn get_campaign_metadata(
            self: @ContractState, campaign_address: ContractAddress
        ) -> ByteArray {
            self.campaign.read(campaign_address).metadata_URI
        }

        fn get_campaigns(self: @ContractState) -> Array<ByteArray> {
            let mut campaigns: Array<ByteArray> = ArrayTrait::new();
            let count: u16 = self.count.read();
            let mut i: u16 = 1;

            while i < count
                + 1 {
                    let campaign_address: ContractAddress = self.campaigns.read(i);
                    let campaign: Campaign = self.campaign.read(campaign_address);
                    campaigns.append(campaign.metadata_URI);
                    i += 1;
                };
            campaigns
        }

        fn get_user_campaigns(self: @ContractState, user: ContractAddress) -> Array<ByteArray> {
            let mut campaigns: Array<ByteArray> = ArrayTrait::new();
            let count: u16 = self.count.read();
            let mut i: u16 = 1;

            while i < count
                + 1 {
                    let campaign_address: ContractAddress = self.campaigns.read(i);
                    let campaign: Campaign = self.campaign.read(campaign_address);
                    if campaign.campaign_owner == user {
                        campaigns.append(campaign.metadata_URI);
                    }
                    i += 1;
                };
            campaigns
        }

        fn get_donation_count(self: @ContractState, campaign_address: ContractAddress) -> u16 {
            self.donation_count.read(campaign_address)
        }
    }
}
