// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts@5.1.0/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts@5.1.0/utils/Strings.sol";
import "@openzeppelin/contracts@5.1.0/utils/Base64.sol";

/// @title QMS Daily v2
/// @notice One GM and one GN per UTC day per wallet. A day counts as a check-in
///         when you send a GM or a GN. The contract tracks total active days
///         (never resets) and your current streak (resets after a missed day),
///         exposes everything the leaderboard needs, and lets you mint rarity
///         badge NFTs at 15, 30, 60, 100 active days. Artwork lives fully on-chain.
contract QMSDailyV2 is ERC721 {
    using Strings for uint256;

    uint8 public constant TIER_COUNT = 4;

    struct Status {
        uint32 gms;
        uint32 gns;
        uint32 activeDays;
        uint32 streak; // live: 0 if you already missed a full day
        uint32 best;
        uint256 gmDay;
        uint256 gnDay;
        uint256 lastActiveDay;
        uint256 mask; // bit i set = badge tier i minted
    }

    struct Row {
        address user;
        uint32 gm;
        uint32 gn;
        uint32 activeDays;
        uint32 streak;
    }

    event GM(address indexed user, uint256 day, uint32 total);
    event GN(address indexed user, uint256 day, uint32 total);
    event CheckIn(address indexed user, uint256 day, uint32 activeDays, uint32 streak);
    event BadgeMinted(address indexed user, uint8 tier, uint256 tokenId);

    mapping(address => uint32) public gmCount;
    mapping(address => uint32) public gnCount;
    mapping(address => uint256) public lastGM;
    mapping(address => uint256) public lastGN;

    mapping(address => uint32) public activeDays;
    mapping(address => uint256) public lastActive;
    mapping(address => uint32) private streakRaw;
    mapping(address => uint32) public bestStreak;

    mapping(address => bool) private known;
    address[] private users;

    uint256 public nextTokenId = 1;
    mapping(uint256 => uint8) public tokenTier;
    mapping(uint256 => uint32) public tokenBestStreak;
    mapping(address => mapping(uint8 => bool)) public minted;

    constructor() ERC721("QMS Daily Badge", "QMSD") {}

    // ---------------------------------------------------------------- daily

    function gm() external {
        uint256 day = block.timestamp / 1 days;
        require(lastGM[msg.sender] != day, "Already GM today");
        lastGM[msg.sender] = day;
        gmCount[msg.sender] += 1;
        _checkIn(msg.sender, day);
        emit GM(msg.sender, day, gmCount[msg.sender]);
    }

    function gn() external {
        uint256 day = block.timestamp / 1 days;
        require(lastGN[msg.sender] != day, "Already GN today");
        lastGN[msg.sender] = day;
        gnCount[msg.sender] += 1;
        _checkIn(msg.sender, day);
        emit GN(msg.sender, day, gnCount[msg.sender]);
    }

    /// @dev A day counts once, whether you send GM, GN or both.
    function _checkIn(address user, uint256 day) private {
        if (!known[user]) {
            known[user] = true;
            users.push(user);
        }
        uint256 last = lastActive[user];
        if (last == day) return;
        activeDays[user] += 1;
        if (last != 0 && last + 1 == day) {
            streakRaw[user] += 1;
        } else {
            streakRaw[user] = 1; // first day, or a day was missed
        }
        if (streakRaw[user] > bestStreak[user]) bestStreak[user] = streakRaw[user];
        lastActive[user] = day;
        emit CheckIn(user, day, activeDays[user], streakRaw[user]);
    }

    /// @notice Your streak right now: 0 once a full day has been missed.
    function currentStreak(address user) public view returns (uint32) {
        uint256 today = block.timestamp / 1 days;
        uint256 last = lastActive[user];
        if (last == 0 || last + 1 < today) return 0;
        return streakRaw[user];
    }

    // ---------------------------------------------------------- leaderboard

    function userCount() external view returns (uint256) {
        return users.length;
    }

    /// @notice Paged list of every participant. The website sorts it into a leaderboard.
    function page(uint256 offset, uint256 limit) external view returns (Row[] memory rows) {
        uint256 len = users.length;
        if (offset >= len) return new Row[](0);
        uint256 end = offset + limit;
        if (end > len) end = len;
        rows = new Row[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            address u = users[i];
            rows[i - offset] = Row(u, gmCount[u], gnCount[u], activeDays[u], currentStreak(u));
        }
    }

    /// @notice Everything the website needs about one wallet in a single call.
    function statusOf(address user) external view returns (Status memory s) {
        s.gms = gmCount[user];
        s.gns = gnCount[user];
        s.activeDays = activeDays[user];
        s.streak = currentStreak(user);
        s.best = bestStreak[user];
        s.gmDay = lastGM[user];
        s.gnDay = lastGN[user];
        s.lastActiveDay = lastActive[user];
        for (uint8 i = 0; i < TIER_COUNT; i++) {
            if (minted[user][i]) s.mask |= (uint256(1) << i);
        }
    }

    // --------------------------------------------------------------- badges

    /// @notice Active days needed for each badge tier.
    function threshold(uint8 tier) public pure returns (uint16) {
        require(tier < TIER_COUNT, "Bad tier");
        if (tier == 0) return 15;
        if (tier == 1) return 30;
        if (tier == 2) return 60;
        if (tier == 3) return 100;
        revert("Bad tier");
    }

    function tierName(uint8 tier) public pure returns (string memory) {
        require(tier < TIER_COUNT, "Bad tier");
        if (tier == 0) return "Ember";
        if (tier == 1) return "Comet";
        if (tier == 2) return "Nova";
        if (tier == 3) return "Singularity";
        revert("Bad tier");
    }

    function rarity(uint8 tier) public pure returns (string memory) {
        require(tier < TIER_COUNT, "Bad tier");
        if (tier == 0) return "Common";
        if (tier == 1) return "Rare";
        if (tier == 2) return "Epic";
        if (tier == 3) return "Legendary";
        revert("Bad tier");
    }

    function _label(uint8 tier) private pure returns (string memory) {
        if (tier == 0) return "COMMON";
        if (tier == 1) return "RARE";
        if (tier == 2) return "EPIC";
        if (tier == 3) return "LEGENDARY";
        revert("Bad tier");
    }

    function _colorA(uint8 tier) private pure returns (string memory) {
        if (tier == 0) return "#fdba74";
        if (tier == 1) return "#67e8f9";
        if (tier == 2) return "#f0abfc";
        if (tier == 3) return "#fff7c2";
        revert("Bad tier");
    }

    function _colorB(uint8 tier) private pure returns (string memory) {
        if (tier == 0) return "#f97316";
        if (tier == 1) return "#3b82f6";
        if (tier == 2) return "#8b5cf6";
        if (tier == 3) return "#f59e0b";
        revert("Bad tier");
    }

    /// @dev Higher rarity = more rings, a frame, sparkles and a glowing dashed halo.
    function _decor(uint8 tier) private pure returns (string memory) {
        if (tier == 0) return "<circle cx='200' cy='156' r='112' fill='none' stroke='url(#g)' stroke-width='6' opacity='0.5'/>";
        if (tier == 1) return "<rect x='8' y='8' width='384' height='384' rx='26' fill='none' stroke='url(#g)' stroke-width='3' opacity='0.6'/><circle cx='200' cy='156' r='112' fill='none' stroke='url(#g)' stroke-width='6' opacity='0.55'/><circle cx='200' cy='156' r='128' fill='none' stroke='url(#g)' stroke-width='3' opacity='0.35'/>";
        if (tier == 2) return "<rect x='8' y='8' width='384' height='384' rx='26' fill='none' stroke='url(#g)' stroke-width='4' opacity='0.75'/><circle cx='200' cy='156' r='112' fill='none' stroke='url(#g)' stroke-width='6' opacity='0.6'/><circle cx='200' cy='156' r='128' fill='none' stroke='url(#g)' stroke-width='3' opacity='0.45'/><circle cx='200' cy='156' r='140' fill='none' stroke='url(#g)' stroke-width='2' opacity='0.3'/><circle cx='56' cy='58' r='5' fill='url(#g)'/><circle cx='344' cy='84' r='4' fill='url(#g)'/><circle cx='70' cy='280' r='4' fill='url(#g)'/><circle cx='334' cy='262' r='5' fill='url(#g)'/>";
        if (tier == 3) return "<rect x='8' y='8' width='384' height='384' rx='26' fill='none' stroke='url(#g)' stroke-width='6' opacity='0.9'/><circle cx='200' cy='156' r='134' fill='none' stroke='url(#g)' stroke-width='12' stroke-dasharray='4 22' opacity='0.85'/><circle cx='200' cy='156' r='112' fill='none' stroke='url(#g)' stroke-width='6' opacity='0.7'/><circle cx='200' cy='156' r='128' fill='none' stroke='url(#g)' stroke-width='3' opacity='0.5'/><circle cx='52' cy='54' r='6' fill='url(#g)'/><circle cx='348' cy='70' r='5' fill='url(#g)'/><circle cx='34' cy='156' r='4' fill='url(#g)'/><circle cx='366' cy='190' r='4' fill='url(#g)'/><circle cx='64' cy='290' r='5' fill='url(#g)'/><circle cx='338' cy='276' r='6' fill='url(#g)'/>";
        revert("Bad tier");
    }

    /// @notice Mint the badge of `tier` once your total active days reach its threshold.
    function mint(uint8 tier) external {
        require(tier < TIER_COUNT, "Bad tier");
        require(activeDays[msg.sender] >= threshold(tier), "Not enough days yet");
        require(!minted[msg.sender][tier], "Already minted");
        minted[msg.sender][tier] = true;
        uint256 id = nextTokenId++;
        tokenTier[id] = tier;
        tokenBestStreak[id] = bestStreak[msg.sender];
        _mint(msg.sender, id);
        emit BadgeMinted(msg.sender, tier, id);
    }

    function _svg(uint8 tier) private pure returns (string memory) {
        string memory a = _colorA(tier);
        string memory num = uint256(threshold(tier)).toString();
        string memory top = string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 400 400'>",
            "<defs><linearGradient id='g' x1='0' y1='0' x2='1' y2='1'>",
            "<stop offset='0' stop-color='", a, "'/><stop offset='1' stop-color='", _colorB(tier), "'/>",
            "</linearGradient></defs>",
            "<rect width='400' height='400' rx='32' fill='#0b0722'/>",
            _decor(tier),
            "<circle cx='200' cy='156' r='96' fill='url(#g)'/>"
        );
        return string.concat(
            top,
            "<text x='200' y='186' font-family='sans-serif' font-size='84' font-weight='700' text-anchor='middle' fill='#0b0722'>", num, "</text>",
            "<text x='200' y='322' font-family='sans-serif' font-size='34' font-weight='700' text-anchor='middle' fill='#ffffff'>", tierName(tier), "</text>",
            "<text x='200' y='348' font-family='sans-serif' font-size='16' font-weight='700' text-anchor='middle' letter-spacing='3' fill='", a, "'>", _label(tier), "</text>",
            "<text x='200' y='374' font-family='sans-serif' font-size='15' text-anchor='middle' fill='#b4abe0'>QMS Daily - ", num, " days</text>",
            "</svg>"
        );
    }

    function _attributes(uint256 tokenId, uint8 tier) private view returns (string memory) {
        return string.concat(
            "\"attributes\":[{\"trait_type\":\"Tier\",\"value\":\"", tierName(tier),
            "\"},{\"trait_type\":\"Rarity\",\"value\":\"", rarity(tier),
            "\"},{\"trait_type\":\"Active days\",\"display_type\":\"number\",\"value\":", uint256(threshold(tier)).toString(),
            "},{\"trait_type\":\"Best streak at mint\",\"display_type\":\"number\",\"value\":", uint256(tokenBestStreak[tokenId]).toString(), "}]"
        );
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        uint8 tier = tokenTier[tokenId];
        string memory json = string.concat(
            "{\"name\":\"QMS Daily ", tierName(tier), " #", tokenId.toString(),
            "\",\"description\":\"", rarity(tier), " badge for ", uint256(threshold(tier)).toString(),
            " active days on QMS Testnet. Artwork stored fully on-chain.\",",
            "\"image\":\"data:image/svg+xml;base64,", Base64.encode(bytes(_svg(tier))), "\",",
            _attributes(tokenId, tier), "}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
