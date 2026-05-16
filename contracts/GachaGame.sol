// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts@5.0.0/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts@5.0.0/access/Ownable.sol";
import "@openzeppelin/contracts@5.0.0/utils/ReentrancyGuard.sol";

// ─────────────────────────────────────────────────────────────
//  WHY ERC-1155 instead of ERC-721?
//  ERC-721 = one contract per unique item (expensive, complex)
//  ERC-1155 = one contract, many item types + quantities
//  Perfect for a game with "100 copies of Iron Sword" etc.
// ─────────────────────────────────────────────────────────────

contract GachaGame is ERC1155, Ownable, ReentrancyGuard {

    // ── ITEM DEFINITIONS ───────────────────────────────────────
    // These are the IDs for each item type.
    // Think of them like Pokemon IDs.
    uint256 public constant IRON_SWORD    = 1;
    uint256 public constant SILVER_BOW    = 2;
    uint256 public constant FIRE_STAFF    = 3;
    uint256 public constant SHADOW_DAGGER = 4;
    uint256 public constant DRAGON_ARMOR  = 5; // legendary - hardest to get

    // ── RARITY WEIGHTS ─────────────────────────────────────────
    // Out of 1000 total weight:
    //   Iron Sword    = 400/1000 = 40% chance
    //   Silver Bow    = 300/1000 = 30% chance
    //   Fire Staff    = 180/1000 = 18% chance
    //   Shadow Dagger =  90/1000 =  9% chance
    //   Dragon Armor  =  30/1000 =  3% chance
    uint256[] public itemIds      = [IRON_SWORD, SILVER_BOW, FIRE_STAFF, SHADOW_DAGGER, DRAGON_ARMOR];
    uint256[] public itemWeights  = [400,        300,        180,        90,            30];
    uint256   public totalWeight  = 1000;

    // ── ROLL PRICE ─────────────────────────────────────────────
    // How much MON (in wei) it costs to do one roll.
    // 0.01 MON = 10_000_000_000_000_000 wei
    // You can change this after deploy by calling setRollPrice()
    uint256 public rollPrice = 0.01 ether;

    // ── MARKETPLACE LISTINGS ───────────────────────────────────
    // Maps a listing ID → Listing struct
    // Anyone can list their items for sale here
    struct Listing {
        address seller;
        uint256 itemId;
        uint256 amount;   // how many copies for sale
        uint256 price;    // price per item in wei
        bool    active;
    }

    uint256 public nextListingId = 1;
    mapping(uint256 => Listing) public listings;

    // ── COMMIT-REVEAL STATE ────────────────────────────────────
    // This is how we do "safe" randomness without a VRF oracle.
    //
    // Problem: if we just use block.prevrandao, a validator could
    // technically manipulate it. Commit-reveal adds a player secret
    // so even a cheating validator can't predict the outcome.
    //
    // Flow:
    //   1. Player calls commitRoll() → pays, stores their secret hash
    //   2. One block passes (so block hash is unknown when they commit)
    //   3. Player calls revealRoll(secret) → result is determined
    //
    // For a hackathon, a simpler (but less safe) approach is fine too —
    // see the simpleRoll() function at the bottom.

    struct Commit {
        bytes32 secretHash;  // keccak256(secret + address) submitted by player
        uint256 blockNumber; // block when they committed
        bool    pending;     // is there an unrevealed commit?
    }
    mapping(address => Commit) public commits;

    // ── EVENTS ─────────────────────────────────────────────────
    // Events are like logs — your frontend listens for these
    // to know something happened without constantly polling.
    event RollCommitted(address indexed player);
    event ItemMinted(address indexed player, uint256 itemId, uint256 amount);
    event Listed(uint256 indexed listingId, address seller, uint256 itemId, uint256 price);
    event Purchased(uint256 indexed listingId, address buyer, uint256 amount);
    event ListingCancelled(uint256 indexed listingId);

    // ── CONSTRUCTOR ────────────────────────────────────────────
    // Runs once when you deploy the contract.
    // The URI is the metadata endpoint for your items.
    // {id} gets replaced by the token ID automatically (ERC-1155 standard).
    constructor()
        ERC1155("https://your-api.com/metadata/{id}.json")
        Ownable(msg.sender)
    {}

    // ═══════════════════════════════════════════════════════════
    //  GACHA ROLLING — COMMIT PHASE
    // ═══════════════════════════════════════════════════════════

    // Step 1: Player picks a secret number (e.g. 42), hashes it off-chain:
    //   secretHash = keccak256(abi.encodePacked(42, msg.sender))
    // Then calls this function with that hash + the roll price.
    function commitRoll(bytes32 secretHash) external payable {
        require(msg.value >= rollPrice, "Not enough MON to roll");
        require(!commits[msg.sender].pending, "You have an unrevealed roll");

        commits[msg.sender] = Commit({
            secretHash:  secretHash,
            blockNumber: block.number,
            pending:     true
        });

        emit RollCommitted(msg.sender);
    }

    // ═══════════════════════════════════════════════════════════
    //  GACHA ROLLING — REVEAL PHASE
    // ═══════════════════════════════════════════════════════════

    // Step 2 (next block): Player reveals their original secret number.
    // We verify it matches the hash, then mix it with the block hash
    // for unpredictable randomness.
    function revealRoll(uint256 secret) external nonReentrant {
        Commit storage c = commits[msg.sender];
        require(c.pending, "No pending commit");
        require(block.number > c.blockNumber, "Wait one block before revealing");
        require(block.number <= c.blockNumber + 250, "Commit expired, commit again"); // ~1 hour window

        // Verify the secret matches what they committed to
        bytes32 expectedHash = keccak256(abi.encodePacked(secret, msg.sender));
        require(c.secretHash == expectedHash, "Secret doesn't match commit");

        // Mix player secret + past block hash → unpredictable random number
        // blockhash() only works for the last 256 blocks, hence the 250 block window above
        uint256 randomSeed = uint256(
            keccak256(abi.encodePacked(secret, blockhash(c.blockNumber), msg.sender))
        );

        // Clear the commit before minting (prevents re-entrancy tricks)
        c.pending = false;

        // Determine which item they got
        uint256 itemId = _pickItem(randomSeed);

        // Mint 1 copy of that item to the player
        _mint(msg.sender, itemId, 1, "");

        emit ItemMinted(msg.sender, itemId, 1);
    }

    // ═══════════════════════════════════════════════════════════
    //  SIMPLE ROLL (hackathon shortcut — less secure but easier)
    // ═══════════════════════════════════════════════════════════
    // Use this if you don't want to implement commit-reveal.
    // Fine for a demo — a determined validator could manipulate it,
    // but that's very unlikely and not worth worrying about for a hackathon.
    function simpleRoll() external payable nonReentrant {
        require(msg.value >= rollPrice, "Not enough MON to roll");

        uint256 randomSeed = uint256(
            keccak256(abi.encodePacked(block.prevrandao, block.timestamp, msg.sender, block.number))
        );

        uint256 itemId = _pickItem(randomSeed);
        _mint(msg.sender, itemId, 1, "");

        emit ItemMinted(msg.sender, itemId, 1);
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL: PICK ITEM FROM WEIGHTS
    // ═══════════════════════════════════════════════════════════
    // Given a random seed, pick an item based on weighted probability.
    // Example: roll 650 out of 1000:
    //   - IRON_SWORD covers 0–399   → no
    //   - SILVER_BOW covers 400–699 → YES
    function _pickItem(uint256 seed) internal view returns (uint256) {
        uint256 roll = seed % totalWeight; // number between 0 and 999
        uint256 cumulative = 0;

        for (uint256 i = 0; i < itemIds.length; i++) {
            cumulative += itemWeights[i];
            if (roll < cumulative) {
                return itemIds[i];
            }
        }

        // Fallback (should never reach here if weights sum to totalWeight)
        return itemIds[0];
    }

    // ═══════════════════════════════════════════════════════════
    //  MARKETPLACE — LIST AN ITEM FOR SALE
    // ═══════════════════════════════════════════════════════════
    // Seller approves this contract first, then calls listItem().
    // The items get locked in the contract until sold or cancelled.
    function listItem(uint256 itemId, uint256 amount, uint256 pricePerItem) external {
        require(amount > 0, "Amount must be > 0");
        require(pricePerItem > 0, "Price must be > 0");

        // Transfer items from seller to this contract (escrow)
        // Seller must have called setApprovalForAll(contractAddress, true) first
        safeTransferFrom(msg.sender, address(this), itemId, amount, "");

        listings[nextListingId] = Listing({
            seller: msg.sender,
            itemId: itemId,
            amount: amount,
            price:  pricePerItem,
            active: true
        });

        emit Listed(nextListingId, msg.sender, itemId, pricePerItem);
        nextListingId++;
    }

    // ═══════════════════════════════════════════════════════════
    //  MARKETPLACE — BUY FROM A LISTING
    // ═══════════════════════════════════════════════════════════
    function buyItem(uint256 listingId, uint256 amount) external payable nonReentrant {
        Listing storage l = listings[listingId];
        require(l.active, "Listing not active");
        require(amount > 0 && amount <= l.amount, "Invalid amount");
        require(msg.value >= l.price * amount, "Not enough MON");

        l.amount -= amount;
        if (l.amount == 0) l.active = false;

        // Send MON to seller
        (bool sent, ) = l.seller.call{value: l.price * amount}("");
        require(sent, "Payment to seller failed");

        // Send items to buyer
        _safeTransferFrom(address(this), msg.sender, l.itemId, amount, "");

        emit Purchased(listingId, msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════════
    //  MARKETPLACE — CANCEL A LISTING
    // ═══════════════════════════════════════════════════════════
    function cancelListing(uint256 listingId) external {
        Listing storage l = listings[listingId];
        require(l.seller == msg.sender, "Not your listing");
        require(l.active, "Already inactive");

        l.active = false;

        // Return unsold items to seller
        _safeTransferFrom(address(this), msg.sender, l.itemId, l.amount, "");

        emit ListingCancelled(listingId);
    }

    // ── OWNER FUNCTIONS ────────────────────────────────────────

    // Change the roll price (only owner/deployer can call this)
    function setRollPrice(uint256 newPrice) external onlyOwner {
        rollPrice = newPrice;
    }

    // Withdraw accumulated MON from rolls to owner wallet
    function withdraw() external onlyOwner {
        (bool sent, ) = owner().call{value: address(this).balance}("");
        require(sent, "Withdraw failed");
    }

    // Required by ERC-1155 so the contract can receive tokens
    function onERC1155Received(address, address, uint256, uint256, bytes memory)
        public pure returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public pure returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}
