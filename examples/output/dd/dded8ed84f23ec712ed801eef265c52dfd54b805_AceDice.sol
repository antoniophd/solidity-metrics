// solium-disable linebreak-style
pragma solidity ^0.5.0;

contract CryptoTycoonsVIPLib{
    
    address payable public owner;
    
    // Accumulated jackpot fund.
    uint128 public jackpotSize;
    uint128 public rankingRewardSize;
    
    mapping (address => uint) userExpPool;
    mapping (address => bool) public callerMap;

    event RankingRewardPayment(address indexed beneficiary, uint amount);

    modifier onlyOwner {
        require(msg.sender == owner, &quot;OnlyOwner methods called by non-owner.&quot;);
        _;
    }

    modifier onlyCaller {
        bool isCaller = callerMap[msg.sender];
        require(isCaller, &quot;onlyCaller methods called by non-caller.&quot;);
        _;
    }

    constructor() public{
        owner = msg.sender;
        callerMap[owner] = true;
    }

    // Fallback function deliberately left empty. It&#39;s primary use case
    // is to top up the bank roll.
    function () external payable {
    }

    function kill() external onlyOwner {
        selfdestruct(owner);
    }

    function addCaller(address caller) public onlyOwner{
        bool isCaller = callerMap[caller];
        if (isCaller == false){
            callerMap[caller] = true;
        }
    }

    function deleteCaller(address caller) external onlyOwner {
        bool isCaller = callerMap[caller];
        if (isCaller == true) {
            callerMap[caller] = false;
        }
    }

    function addUserExp(address addr, uint256 amount) public onlyCaller{
        uint exp = userExpPool[addr];
        exp = exp + amount;
        userExpPool[addr] = exp;
    }

    function getUserExp(address addr) public view returns(uint256 exp){
        return userExpPool[addr];
    }

    function getVIPLevel(address user) public view returns (uint256 level) {
        uint exp = userExpPool[user];

        if(exp >= 25 ether && exp < 125 ether){
            level = 1;
        } else if(exp >= 125 ether && exp < 250 ether){
            level = 2;
        } else if(exp >= 250 ether && exp < 1250 ether){
            level = 3;
        } else if(exp >= 1250 ether && exp < 2500 ether){
            level = 4;
        } else if(exp >= 2500 ether && exp < 12500 ether){
            level = 5;
        } else if(exp >= 12500 ether && exp < 25000 ether){
            level = 6;
        } else if(exp >= 25000 ether && exp < 125000 ether){
            level = 7;
        } else if(exp >= 125000 ether && exp < 250000 ether){
            level = 8;
        } else if(exp >= 250000 ether && exp < 1250000 ether){
            level = 9;
        } else if(exp >= 1250000 ether){
            level = 10;
        } else{
            level = 0;
        }

        return level;
    }

    function getVIPBounusRate(address user) public view returns (uint256 rate){
        uint level = getVIPLevel(user);
        return level;
    }

    // This function is used to bump up the jackpot fund. Cannot be used to lower it.
    function increaseJackpot(uint increaseAmount) external onlyCaller {
        require (increaseAmount <= address(this).balance, &quot;Increase amount larger than balance.&quot;);
        require (jackpotSize + increaseAmount <= address(this).balance, &quot;Not enough funds.&quot;);
        jackpotSize += uint128(increaseAmount);
    }

    function payJackpotReward(address payable to) external onlyCaller{
        to.transfer(jackpotSize);
        jackpotSize = 0;
    }

    function getJackpotSize() external view returns (uint256){
        return jackpotSize;
    }

    function increaseRankingReward(uint amount) public onlyCaller{
        require (amount <= address(this).balance, &quot;Increase amount larger than balance.&quot;);
        require (rankingRewardSize + amount <= address(this).balance, &quot;Not enough funds.&quot;);
        rankingRewardSize += uint128(amount);
    }

    function payRankingReward(address payable to) external onlyCaller {
        uint128 prize = rankingRewardSize / 2;
        rankingRewardSize = rankingRewardSize - prize;
        if(to.send(prize)){
            emit RankingRewardPayment(to, prize);
        }
    }

    function getRankingRewardSize() external view returns (uint128){
        return rankingRewardSize;
    }
}

contract AceDice {
    /// *** Constants section

    // Each bet is deducted 1% in favour of the house, but no less than some minimum.
    // The lower bound is dictated by gas costs of the settleBet transaction, providing
    // headroom for up to 10 Gwei prices.
    uint constant HOUSE_EDGE_PERCENT = 1;
    uint constant HOUSE_EDGE_MINIMUM_AMOUNT = 0.0004 ether;

    // Bets lower than this amount do not participate in jackpot rolls (and are
    // not deducted JACKPOT_FEE).
    uint constant MIN_JACKPOT_BET = 0.1 ether;

    // Chance to win jackpot (currently 0.1%) and fee deducted into jackpot fund.
    uint constant JACKPOT_MODULO = 1000;
    uint constant JACKPOT_FEE = 0.001 ether;

    // There is minimum and maximum bets.
    uint constant MIN_BET = 0.01 ether;
    uint constant MAX_AMOUNT = 300000 ether;

    // Modulo is a number of equiprobable outcomes in a game:
    // - 2 for coin flip
    // - 6 for dice
    // - 6*6 = 36 for double dice
    // - 100 for etheroll
    // - 37 for roulette
    // etc.
    // It&#39;s called so because 256-bit entropy is treated like a huge integer and
    // the remainder of its division by modulo is considered bet outcome.
    // uint constant MAX_MODULO = 100;

    // For modulos below this threshold rolls are checked against a bit mask,
    // thus allowing betting on any combination of outcomes. For example, given
    // modulo 6 for dice, 101000 mask (base-2, big endian) means betting on
    // 4 and 6; for games with modulos higher than threshold (Etheroll), a simple
    // limit is used, allowing betting on any outcome in [0, N) range.
    //
    // The specific value is dictated by the fact that 256-bit intermediate
    // multiplication result allows implementing population count efficiently
    // for numbers that are up to 42 bits, and 40 is the highest multiple of
    // eight below 42.
    uint constant MAX_MASK_MODULO = 40;

    // This is a check on bet mask overflow.
    uint constant MAX_BET_MASK = 2 ** MAX_MASK_MODULO;

    // EVM BLOCKHASH opcode can query no further than 256 blocks into the
    // past. Given that settleBet uses block hash of placeBet as one of
    // complementary entropy sources, we cannot process bets older than this
    // threshold. On rare occasions AceDice croupier may fail to invoke
    // settleBet in this timespan due to technical issues or extreme Ethereum
    // congestion; such bets can be refunded via invoking refundBet.
    uint constant BET_EXPIRATION_BLOCKS = 250;

    // Some deliberately invalid address to initialize the secret signer with.
    // Forces maintainers to invoke setSecretSigner before processing any bets.
    address constant DUMMY_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Standard contract ownership transfer.
    address payable public owner;
    address payable private nextOwner;

    // Adjustable max bet profit. Used to cap bets against dynamic odds.
    uint public maxProfit;

    // The address corresponding to a private key used to sign placeBet commits.
    address public secretSigner;

    // Funds that are locked in potentially winning bets. Prevents contract from
    // committing to bets it cannot pay out.
    uint128 public lockedInBets;

    // A structure representing a single bet.
    struct Bet {
        // Wager amount in wei.
        uint amount;
        // Modulo of a game.
        // uint8 modulo;
        // Number of winning outcomes, used to compute winning payment (* modulo/rollUnder),
        // and used instead of mask for games with modulo > MAX_MASK_MODULO.
        uint8 rollUnder;
        // Block number of placeBet tx.
        uint40 placeBlockNumber;
        // Bit mask representing winning bet outcomes (see MAX_MASK_MODULO comment).
        uint40 mask;
        // Address of a gambler, used to pay out winning bets.
        address payable gambler;
        // Address of inviter
        address payable inviter;
    }

    struct Profile{
        // picture index of profile avatar
        uint avatarIndex;
        // nickname of user
        bytes32 nickName;
    }

    // Mapping from commits to all currently active & processed bets.
    mapping (uint => Bet) bets;

    mapping (address => Profile) profiles;

    // Croupier account.
    mapping (address => bool ) croupierMap;

    address payable public VIPLibraryAddress;

    // Events that are issued to make statistic recovery easier.
    event FailedPayment(address indexed beneficiary, uint amount);
    event Payment(address indexed beneficiary, uint amount, uint dice, uint rollUnder, uint betAmount);
    event JackpotPayment(address indexed beneficiary, uint amount, uint dice, uint rollUnder, uint betAmount);
    event VIPPayback(address indexed beneficiary, uint amount);

    // This event is emitted in placeBet to record commit in the logs.
    event Commit(uint commit);

    // Constructor. Deliberately does not take any parameters.
    constructor () public {
        owner = msg.sender;
        secretSigner = DUMMY_ADDRESS;
    }

    // Standard modifier on methods invokable only by contract owner.
    modifier onlyOwner {
        require (msg.sender == owner, &quot;OnlyOwner methods called by non-owner.&quot;);
        _;
    }

    // Standard modifier on methods invokable only by contract owner.
    modifier onlyCroupier {
    bool isCroupier = croupierMap[msg.sender];
        require(isCroupier, &quot;OnlyCroupier methods called by non-croupier.&quot;);
        _;
    }

    // Standard contract ownership transfer implementation,
    function approveNextOwner(address payable _nextOwner) external onlyOwner {
        require (_nextOwner != owner, &quot;Cannot approve current owner.&quot;);
        nextOwner = _nextOwner;
    }

    function acceptNextOwner() external {
        require (msg.sender == nextOwner, &quot;Can only accept preapproved new owner.&quot;);
        owner = nextOwner;
    }

    // Fallback function deliberately left empty. It&#39;s primary use case
    // is to top up the bank roll.
    function () external payable {
    }

    // See comment for &quot;secretSigner&quot; variable.
    function setSecretSigner(address newSecretSigner) external onlyOwner {
        secretSigner = newSecretSigner;
    }

    function getSecretSigner() external onlyOwner view returns(address){
        return secretSigner;
    }

    function addCroupier(address newCroupier) external onlyOwner {
        bool isCroupier = croupierMap[newCroupier];
        if (isCroupier == false) {
            croupierMap[newCroupier] = true;
        }
    }
    
    function deleteCroupier(address newCroupier) external onlyOwner {
        bool isCroupier = croupierMap[newCroupier];
        if (isCroupier == true) {
            croupierMap[newCroupier] = false;
        }
    }

    function setVIPLibraryAddress(address payable addr) external onlyOwner{
        VIPLibraryAddress = addr;
    }

    // Change max bet reward. Setting this to zero effectively disables betting.
    function setMaxProfit(uint _maxProfit) public onlyOwner {
        require (_maxProfit < MAX_AMOUNT, &quot;maxProfit should be a sane number.&quot;);
        maxProfit = _maxProfit;
    }

    // Funds withdrawal to cover costs of AceDice operation.
    function withdrawFunds(address payable beneficiary, uint withdrawAmount) external onlyOwner {
        require (withdrawAmount <= address(this).balance, &quot;Increase amount larger than balance.&quot;);
        require (lockedInBets + withdrawAmount <= address(this).balance, &quot;Not enough funds.&quot;);
        sendFunds(beneficiary, withdrawAmount, withdrawAmount, 0, 0, 0);
    }

    function kill() external onlyOwner {
        require (lockedInBets == 0, &quot;All bets should be processed (settled or refunded) before self-destruct.&quot;);
        selfdestruct(owner);
    }

    function encodePacketCommit(uint commitLastBlock, uint commit) private pure returns(bytes memory){
        return abi.encodePacked(uint40(commitLastBlock), commit);
    }

    function verifyCommit(uint commitLastBlock, uint commit, uint8 v, bytes32 r, bytes32 s) private view {
        // Check that commit is valid - it has not expired and its signature is valid.
        require (block.number <= commitLastBlock, &quot;Commit has expired.&quot;);
        //bytes32 signatureHash = keccak256(abi.encodePacked(commitLastBlock, commit));
        bytes memory prefix = &quot;\x19Ethereum Signed Message:\n32&quot;;
        bytes memory message = encodePacketCommit(commitLastBlock, commit);
        bytes32 messageHash = keccak256(abi.encodePacked(prefix, keccak256(message)));
        require (secretSigner == ecrecover(messageHash, v, r, s), &quot;ECDSA signature is not valid.&quot;);
    }

    function placeBet(uint betMask, uint commitLastBlock, uint commit, uint8 v, bytes32 r, bytes32 s) external payable {
        // Check that the bet is in &#39;clean&#39; state.
        Bet storage bet = bets[commit];
        require (bet.gambler == address(0), &quot;Bet should be in a &#39;clean&#39; state.&quot;);

        // Validate input data ranges.
        uint amount = msg.value;
        //require (modulo > 1 && modulo <= MAX_MODULO, &quot;Modulo should be within range.&quot;);
        require (amount >= MIN_BET && amount <= MAX_AMOUNT, &quot;Amount should be within range.&quot;);
        require (betMask > 0 && betMask < MAX_BET_MASK, &quot;Mask should be within range.&quot;);

        verifyCommit(commitLastBlock, commit, v, r, s);

        // uint rollUnder;
        uint mask;

        // if (modulo <= MAX_MASK_MODULO) {
        //   // Small modulo games specify bet outcomes via bit mask.
        //   // rollUnder is a number of 1 bits in this mask (population count).
        //   // This magic looking formula is an efficient way to compute population
        //   // count on EVM for numbers below 2**40. For detailed proof consult
        //   // the AceDice whitepaper.
        //   rollUnder = ((betMask * POPCNT_MULT) & POPCNT_MASK) % POPCNT_MODULO;
        //   mask = betMask;
        //   } else {
        // Larger modulos specify the right edge of half-open interval of
        // winning bet outcomes.
        require (betMask > 0 && betMask <= 100, &quot;High modulo range, betMask larger than modulo.&quot;);
        // rollUnder = betMask;
        // }

        // Winning amount and jackpot increase.
        uint possibleWinAmount;
        uint jackpotFee;

        (possibleWinAmount, jackpotFee) = getDiceWinAmount(amount, betMask);

        // Enforce max profit limit.
        require (possibleWinAmount <= amount + maxProfit, &quot;maxProfit limit violation. &quot;);

        // Lock funds.
        lockedInBets += uint128(possibleWinAmount);

        // Check whether contract has enough funds to process this bet.
        require (jackpotFee + lockedInBets <= address(this).balance, &quot;Cannot afford to lose this bet.&quot;);

        // Record commit in logs.
        emit Commit(commit);

        // Store bet parameters on blockchain.
        bet.amount = amount;
        // bet.modulo = uint8(modulo);
        bet.rollUnder = uint8(betMask);
        bet.placeBlockNumber = uint40(block.number);
        bet.mask = uint40(mask);
        bet.gambler = msg.sender;

        CryptoTycoonsVIPLib vipLib = CryptoTycoonsVIPLib(VIPLibraryAddress);
        vipLib.addUserExp(msg.sender, amount);
    }

    function placeBetWithInviter(uint betMask, uint commitLastBlock, uint commit, uint8 v, bytes32 r, bytes32 s, address payable inviter) external payable {
        // Check that the bet is in &#39;clean&#39; state.
        Bet storage bet = bets[commit];
        require (bet.gambler == address(0), &quot;Bet should be in a &#39;clean&#39; state.&quot;);

        // Validate input data ranges.
        uint amount = msg.value;
        // require (modulo > 1 && modulo <= MAX_MODULO, &quot;Modulo should be within range.&quot;);
        require (amount >= MIN_BET && amount <= MAX_AMOUNT, &quot;Amount should be within range.&quot;);
        require (betMask > 0 && betMask < MAX_BET_MASK, &quot;Mask should be within range.&quot;);
        require (address(this) != inviter && inviter != address(0), &quot;cannot invite mysql&quot;);

        verifyCommit(commitLastBlock, commit, v, r, s);

        // uint rollUnder;
        uint mask;

        // if (modulo <= MAX_MASK_MODULO) {
        //   // Small modulo games specify bet outcomes via bit mask.
        //   // rollUnder is a number of 1 bits in this mask (population count).
        //   // This magic looking formula is an efficient way to compute population
        //   // count on EVM for numbers below 2**40. For detailed proof consult
        //   // the AceDice whitepaper.
        //   rollUnder = ((betMask * POPCNT_MULT) & POPCNT_MASK) % POPCNT_MODULO;
        //   mask = betMask;
        // } else {
        // Larger modulos specify the right edge of half-open interval of
        // winning bet outcomes.
        require (betMask > 0 && betMask <= 100, &quot;High modulo range, betMask larger than modulo.&quot;);
        // rollUnder = betMask;
        // }

        // Winning amount and jackpot increase.
        uint possibleWinAmount;
        uint jackpotFee;

        (possibleWinAmount, jackpotFee) = getDiceWinAmount(amount, betMask);

        // Enforce max profit limit.
        require (possibleWinAmount <= amount + maxProfit, &quot;maxProfit limit violation. &quot;);

        // Lock funds.
        lockedInBets += uint128(possibleWinAmount);
        // jackpotSize += uint128(jackpotFee);

        // Check whether contract has enough funds to process this bet.
        require (jackpotFee + lockedInBets <= address(this).balance, &quot;Cannot afford to lose this bet.&quot;);

        // Record commit in logs.
        emit Commit(commit);

        // Store bet parameters on blockchain.
        bet.amount = amount;
        // bet.modulo = uint8(modulo);
        bet.rollUnder = uint8(betMask);
        bet.placeBlockNumber = uint40(block.number);
        bet.mask = uint40(mask);
        bet.gambler = msg.sender;
        bet.inviter = inviter;

        CryptoTycoonsVIPLib vipLib = CryptoTycoonsVIPLib(VIPLibraryAddress);
        vipLib.addUserExp(msg.sender, amount);
    }
    
    function applyVIPLevel(address payable gambler, uint amount) private {
        CryptoTycoonsVIPLib vipLib = CryptoTycoonsVIPLib(VIPLibraryAddress);
        uint rate = vipLib.getVIPBounusRate(gambler);

        if (rate <= 0)
            return;

        uint vipPayback = amount * rate / 10000;
        if(gambler.send(vipPayback)){
            emit VIPPayback(gambler, vipPayback);
        }
    }

    function getMyAccuAmount() external view returns (uint){
        CryptoTycoonsVIPLib vipLib = CryptoTycoonsVIPLib(VIPLibraryAddress);
        return vipLib.getUserExp(msg.sender);
    }

    function getJackpotSize() external view returns (uint){
        CryptoTycoonsVIPLib vipLib = CryptoTycoonsVIPLib(VIPLibraryAddress);
        return vipLib.getJackpotSize();
    }

    // This is the method used to settle 99% of bets. To process a bet with a specific
    // &quot;commit&quot;, settleBet should supply a &quot;reveal&quot; number that would Keccak256-hash to
    // &quot;commit&quot;. &quot;blockHash&quot; is the block hash of placeBet block as seen by croupier; it
    // is additionally asserted to prevent changing the bet outcomes on Ethereum reorgs.
    function settleBet(uint reveal, bytes32 blockHash) external onlyCroupier {
        uint commit = uint(keccak256(abi.encodePacked(reveal)));

        Bet storage bet = bets[commit];
        uint placeBlockNumber = bet.placeBlockNumber;

        // Check that bet has not expired yet (see comment to BET_EXPIRATION_BLOCKS).
        require (block.number > placeBlockNumber, &quot;settleBet in the same block as placeBet, or before.&quot;);
        require (block.number <= placeBlockNumber + BET_EXPIRATION_BLOCKS, &quot;Blockhash can&#39;t be queried by EVM.&quot;);
        require (blockhash(placeBlockNumber) == blockHash);

        // Settle bet using reveal and blockHash as entropy sources.
        settleBetCommon(bet, reveal, blockHash);
    }

        // Common settlement code for settleBet & settleBetUncleMerkleProof.
    function settleBetCommon(Bet storage bet, uint reveal, bytes32 entropyBlockHash) private {
        // Fetch bet parameters into local variables (to save gas).
        uint amount = bet.amount;
        // uint modulo = bet.modulo;
        uint rollUnder = bet.rollUnder;
        address payable gambler = bet.gambler;

        // Check that bet is in &#39;active&#39; state.
        require (amount != 0, &quot;Bet should be in an &#39;active&#39; state&quot;);

        applyVIPLevel(gambler, amount);

        // Move bet into &#39;processed&#39; state already.
        bet.amount = 0;

        // The RNG - combine &quot;reveal&quot; and blockhash of placeBet using Keccak256. Miners
        // are not aware of &quot;reveal&quot; and cannot deduce it from &quot;commit&quot; (as Keccak256
        // preimage is intractable), and house is unable to alter the &quot;reveal&quot; after
        // placeBet have been mined (as Keccak256 collision finding is also intractable).
        bytes32 entropy = keccak256(abi.encodePacked(reveal, entropyBlockHash));

        // Do a roll by taking a modulo of entropy. Compute winning amount.
        uint dice = uint(entropy) % 100;

        uint diceWinAmount;
        uint _jackpotFee;
        (diceWinAmount, _jackpotFee) = getDiceWinAmount(amount, rollUnder);

        uint diceWin = 0;
        uint jackpotWin = 0;


        if (dice < rollUnder) {
            diceWin = diceWinAmount;
        }

        // Unlock the bet amount, regardless of the outcome.
        lockedInBets -= uint128(diceWinAmount);
        
        CryptoTycoonsVIPLib vipLib = CryptoTycoonsVIPLib(VIPLibraryAddress);
                
        // Roll for a jackpot (if eligible).
        if (amount >= MIN_JACKPOT_BET) {
            
            VIPLibraryAddress.transfer(_jackpotFee);
            vipLib.increaseJackpot(_jackpotFee);

            // The second modulo, statistically independent from the &quot;main&quot; dice roll.
            // Effectively you are playing two games at once!
            // uint jackpotRng = (uint(entropy) / modulo) % JACKPOT_MODULO;

            // Bingo!
            if ((uint(entropy) / 100) % JACKPOT_MODULO == 0) {
                jackpotWin = vipLib.getJackpotSize();
                vipLib.payJackpotReward(gambler);
            }
        }

        // Log jackpot win.
        if (jackpotWin > 0) {
            emit JackpotPayment(gambler, jackpotWin, dice, rollUnder, amount);
        }

        if(bet.inviter != address(0)){
            // pay 10% of house edge to inviter
            bet.inviter.transfer(amount * HOUSE_EDGE_PERCENT / 100 * 7 /100);
        }

        // uint128 rankingRewardFee = uint128(amount * HOUSE_EDGE_PERCENT / 100 * 9 /100);
        VIPLibraryAddress.transfer(uint128(amount * HOUSE_EDGE_PERCENT / 100 * 7 /100));
        vipLib.increaseRankingReward(uint128(amount * HOUSE_EDGE_PERCENT / 100 * 7 /100));

        // Send the funds to gambler.
        sendFunds(gambler, diceWin == 0 ? 1 wei : diceWin, diceWin, dice, rollUnder, amount);
    }

    // Refund transaction - return the bet amount of a roll that was not processed in a
    // due timeframe. Processing such blocks is not possible due to EVM limitations (see
    // BET_EXPIRATION_BLOCKS comment above for details). In case you ever find yourself
    // in a situation like this, just contact the AceDice support, however nothing
    // precludes you from invoking this method yourself.
    function refundBet(uint commit) external {
        // Check that bet is in &#39;active&#39; state.
        Bet storage bet = bets[commit];
        uint amount = bet.amount;

        require (amount != 0, &quot;Bet should be in an &#39;active&#39; state&quot;);

        // Check that bet has already expired.
        require (block.number > bet.placeBlockNumber + BET_EXPIRATION_BLOCKS, &quot;Blockhash can&#39;t be queried by EVM.&quot;);

        // Move bet into &#39;processed&#39; state, release funds.
        bet.amount = 0;

        uint diceWinAmount;
        uint jackpotFee;
        (diceWinAmount, jackpotFee) = getDiceWinAmount(amount, bet.rollUnder);

        lockedInBets -= uint128(diceWinAmount);
        // jackpotSize -= uint128(jackpotFee);
        CryptoTycoonsVIPLib vipLib = CryptoTycoonsVIPLib(VIPLibraryAddress);
        vipLib.increaseJackpot(-jackpotFee);

        // Send the refund.
        sendFunds(bet.gambler, amount, amount, 0, 0, 0);
    }

    // Get the expected win amount after house edge is subtracted.
    function getDiceWinAmount(uint amount, uint rollUnder) private pure returns (uint winAmount, uint jackpotFee) {
        require (0 < rollUnder && rollUnder <= 100, &quot;Win probability out of range.&quot;);

        jackpotFee = amount >= MIN_JACKPOT_BET ? JACKPOT_FEE : 0;

        uint houseEdge = amount * HOUSE_EDGE_PERCENT / 100;

        if (houseEdge < HOUSE_EDGE_MINIMUM_AMOUNT) {
        houseEdge = HOUSE_EDGE_MINIMUM_AMOUNT;
        }

        require (houseEdge + jackpotFee <= amount, &quot;Bet doesn&#39;t even cover house edge.&quot;);
        winAmount = (amount - houseEdge - jackpotFee) * 100 / rollUnder;
    }

    // Helper routine to process the payment.
    function sendFunds(address payable beneficiary, uint amount, uint successLogAmount, uint dice, uint rollUnder, uint betAmount) private {
        if (beneficiary.send(amount)) {
            emit Payment(beneficiary, successLogAmount, dice, rollUnder, betAmount);
        } else {
            emit FailedPayment(beneficiary, amount);
        }
    }

    function thisBalance() public view returns(uint) {
        return address(this).balance;
    }

    function setAvatarIndex(uint index) external{
        require (index >=0 && index <= 100, &quot;avatar index should be in range&quot;);
        Profile storage profile = profiles[msg.sender];
        profile.avatarIndex = index;
    }

    function setNickName(bytes32 nickName) external{
        Profile storage profile = profiles[msg.sender];
        profile.nickName = nickName;
    }

    function getProfile() external view returns(uint, bytes32){
        Profile storage profile = profiles[msg.sender];
        return (profile.avatarIndex, profile.nickName);
    }

    function payTodayReward(address payable to) external onlyOwner {
        CryptoTycoonsVIPLib vipLib = CryptoTycoonsVIPLib(VIPLibraryAddress);
        vipLib.payRankingReward(to);
    }

    function getRankingRewardSize() external view returns (uint128) {
        CryptoTycoonsVIPLib vipLib = CryptoTycoonsVIPLib(VIPLibraryAddress);
        return vipLib.getRankingRewardSize();
    }
}