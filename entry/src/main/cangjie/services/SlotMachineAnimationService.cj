package ohos_app_cangjie_entry.services

// SlotMachineAnimationService: decodes Telegram dice value (1-64) into three reel symbols.
// No MTProto interaction — dice value arrives as part of the message, N/A for this layer.

// Possible symbol on a single reel slot
public enum ReelSymbol {
    | Rolling     // still spinning, no result yet
    | Bar
    | Berry
    | Lemon
    | Seven
    | SevenWin    // seven that is part of a triple-seven jackpot
}

// Decoded state for all three reels
public class SlotMachineReelState {
    public var left: ReelSymbol = ReelSymbol.Rolling
    public var center: ReelSymbol = ReelSymbol.Rolling
    public var right: ReelSymbol = ReelSymbol.Rolling

    public init(left!: ReelSymbol, center!: ReelSymbol, right!: ReelSymbol) {
        this.left = left
        this.center = center
        this.right = right
    }

    // True when all three reels show the same result symbol
    public func isThreeOfSame(): Bool {
        let lIsResult = this.symbolIsResult(this.left)
        let cIsResult = this.symbolIsResult(this.center)
        let rIsResult = this.symbolIsResult(this.right)
        if (!lIsResult || !cIsResult || !rIsResult) {
            return false
        }
        return this.symbolEqual(this.left, this.center) && this.symbolEqual(this.center, this.right)
    }

    // True when the result is the jackpot triple-seven
    public func isJackpot(): Bool {
        return match (this.left) {
            case SevenWin => match (this.center) {
                case SevenWin => match (this.right) {
                    case SevenWin => true
                    case _ => false
                }
                case _ => false
            }
            case _ => false
        }
    }

    private func symbolIsResult(sym: ReelSymbol): Bool {
        return match (sym) {
            case Rolling => false
            case _ => true
        }
    }

    private func symbolEqual(a: ReelSymbol, b: ReelSymbol): Bool {
        return match (a) {
            case Rolling => match (b) { case Rolling => true; case _ => false }
            case Bar => match (b) { case Bar => true; case _ => false }
            case Berry => match (b) { case Berry => true; case _ => false }
            case Lemon => match (b) { case Lemon => true; case _ => false }
            case Seven => match (b) { case Seven => true; case _ => false }
            case SevenWin => match (b) { case SevenWin => true; case _ => false }
        }
    }
}

// Service: stateless helper, pure function decoding
public class SlotMachineAnimationService {

    public init() {}

    // Decode a Telegram dice value (Int32, 1-64) into three reel symbols.
    // Value 0 or null → all Rolling (animation in progress, result not yet known).
    // Bit layout (matches Telegram-iOS SlotMachineValue):
    //   adjusted = rawValue - 1
    //   left   = adjusted & 0x03
    //   center = (adjusted >> 2) & 0x03
    //   right  = (adjusted >> 4)
    // Per-reel mapping: 0 → Bar, 1 → Berry, 2 → Lemon, 3 → Seven
    public func decodeValue(rawValue: Int32): SlotMachineReelState {
        if (rawValue <= 0) {
            return SlotMachineReelState(
                left: ReelSymbol.Rolling,
                center: ReelSymbol.Rolling,
                right: ReelSymbol.Rolling
            )
        }
        let adjusted = rawValue - 1
        let leftRaw = adjusted & 3
        let centerRaw = (adjusted >> 2) & 3
        let rightRaw = (adjusted >> 4)

        var leftSym = this.rawToSymbol(leftRaw)
        var centerSym = this.rawToSymbol(centerRaw)
        var rightSym = this.rawToSymbol(rightRaw)

        // Promote all three Sevens to SevenWin (jackpot)
        let allSeven = match (leftSym) {
            case Seven => match (centerSym) {
                case Seven => match (rightSym) { case Seven => true; case _ => false }
                case _ => false
            }
            case _ => false
        }
        if (allSeven) {
            leftSym = ReelSymbol.SevenWin
            centerSym = ReelSymbol.SevenWin
            rightSym = ReelSymbol.SevenWin
        }

        return SlotMachineReelState(left: leftSym, center: centerSym, right: rightSym)
    }

    // Returns a human-readable label used as reel display text
    public func symbolLabel(sym: ReelSymbol): String {
        return match (sym) {
            case Rolling => "~"
            case Bar => "BAR"
            case Berry => "🍒"
            case Lemon => "🍋"
            case Seven => "7"
            case SevenWin => "7★"
        }
    }

    // Returns a background color hex value for a reel symbol
    public func symbolColor(sym: ReelSymbol): Int64 {
        return match (sym) {
            case Rolling => 0xFFBBBBBB
            case Bar => 0xFFFFD700
            case Berry => 0xFFFF4444
            case Lemon => 0xFFFFEE44
            case Seven => 0xFF4444FF
            case SevenWin => 0xFFFF8800
        }
    }

    private func rawToSymbol(raw: Int32): ReelSymbol {
        return match (raw) {
            case 0 => ReelSymbol.Bar
            case 1 => ReelSymbol.Berry
            case 2 => ReelSymbol.Lemon
            case 3 => ReelSymbol.Seven
            case _ => ReelSymbol.Rolling
        }
    }
}
