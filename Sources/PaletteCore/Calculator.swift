import Foundation

public enum Calculator {
    public struct Result: Equatable, Sendable {
        public var value: Double
        public var formatted: String
    }

    public static func evaluate(_ input: String) -> Result? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("=") {
            text.removeFirst()
        }
        text = text
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
        guard !text.isEmpty else { return nil }
        guard let tokens = tokenize(text) else { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = parser.parse(), parser.isAtEnd else { return nil }
        guard value.isFinite else { return nil }
        return Result(value: value, formatted: format(value))
    }

    /// Whether a plain query is worth handing to the calculator at all.
    public static func looksLikeExpression(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if text.hasPrefix("=") { return true }
        let lowered = text.lowercased()
        let functionPrefixes = ["sqrt(", "sin(", "cos(", "tan(", "log(", "ln(", "abs("]
        if functionPrefixes.contains(where: { lowered.hasPrefix($0) }) { return true }
        guard text.contains(where: \.isNumber) else { return false }
        if Double(text) != nil { return true }
        let operators = CharacterSet(charactersIn: "+-*/%^()")
        return text.rangeOfCharacter(from: operators) != nil
    }

    public static func format(_ value: Double) -> String {
        if value == 0 { return "0" }
        if value.rounded() == value, abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.10g", value)
    }

    // MARK: - Tokenizer

    private enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case plus, minus, times, divide, modulo, power
        case leftParen, rightParen, percent
    }

    private static func tokenize(_ text: String) -> [Token]? {
        var tokens: [Token] = []
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                continue
            }

            if character.isNumber || (character == "." && index + 1 < characters.count && characters[index + 1].isNumber) {
                var literal = String(character)
                index += 1
                while index < characters.count, characters[index].isNumber || characters[index] == "." {
                    literal.append(characters[index])
                    index += 1
                }
                if index < characters.count, characters[index] == "e" || characters[index] == "E" {
                    var exponent = String(characters[index])
                    var cursor = index + 1
                    if cursor < characters.count, characters[cursor] == "+" || characters[cursor] == "-" {
                        exponent.append(characters[cursor])
                        cursor += 1
                    }
                    var digits = 0
                    while cursor < characters.count, characters[cursor].isNumber {
                        exponent.append(characters[cursor])
                        cursor += 1
                        digits += 1
                    }
                    if digits > 0 {
                        literal += exponent
                        index = cursor
                    }
                }
                guard let value = Double(literal) else { return nil }
                tokens.append(.number(value))
                continue
            }

            if character.isLetter {
                var identifier = String(character)
                index += 1
                while index < characters.count, characters[index].isLetter {
                    identifier.append(characters[index])
                    index += 1
                }
                tokens.append(.identifier(identifier.lowercased()))
                continue
            }

            switch character {
            case "+": tokens.append(.plus)
            case "-": tokens.append(.minus)
            case "*": tokens.append(.times)
            case "/": tokens.append(.divide)
            case "%": tokens.append(.percent)
            case "^": tokens.append(.power)
            case "(": tokens.append(.leftParen)
            case ")": tokens.append(.rightParen)
            default: return nil
            }
            index += 1
        }

        return tokens
    }

    // MARK: - Parser

    private struct Parser {
        let tokens: [Token]
        var index = 0

        init(tokens: [Token]) {
            self.tokens = tokens
        }

        var isAtEnd: Bool { index >= tokens.count }

        mutating func parse() -> Double? {
            parseExpression()
        }

        private func peek() -> Token? {
            index < tokens.count ? tokens[index] : nil
        }

        private mutating func advance() -> Token? {
            guard index < tokens.count else { return nil }
            defer { index += 1 }
            return tokens[index]
        }

        private mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while let token = peek() {
                if token == .plus {
                    _ = advance()
                    guard let rhs = parseTerm() else { return nil }
                    value += rhs
                } else if token == .minus {
                    _ = advance()
                    guard let rhs = parseTerm() else { return nil }
                    value -= rhs
                } else {
                    break
                }
            }
            return value
        }

        private mutating func parseTerm() -> Double? {
            guard var value = parseUnary() else { return nil }
            while let token = peek() {
                if token == .times {
                    _ = advance()
                    guard let rhs = parseUnary() else { return nil }
                    value *= rhs
                } else if token == .divide {
                    _ = advance()
                    guard let rhs = parseUnary(), rhs != 0 else { return nil }
                    value /= rhs
                } else if token == .modulo {
                    _ = advance()
                    guard let rhs = parseUnary(), rhs != 0 else { return nil }
                    value = value.truncatingRemainder(dividingBy: rhs)
                } else {
                    break
                }
            }
            return value
        }

        private mutating func parseUnary() -> Double? {
            if peek() == .plus {
                _ = advance()
                return parseUnary()
            }
            if peek() == .minus {
                _ = advance()
                guard let value = parseUnary() else { return nil }
                return -value
            }
            return parsePower()
        }

        private mutating func parsePower() -> Double? {
            guard let base = parsePostfix() else { return nil }
            if peek() == .power {
                _ = advance()
                guard let exponent = parseUnary() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        private mutating func parsePostfix() -> Double? {
            guard var value = parsePrimary() else { return nil }
            while peek() == .percent {
                _ = advance()
                value /= 100
            }
            return value
        }

        private mutating func parsePrimary() -> Double? {
            guard let token = advance() else { return nil }

            switch token {
            case .number(let value):
                return value
            case .leftParen:
                guard let value = parseExpression(), advance() == .rightParen else { return nil }
                return value
            case .identifier(let name):
                if name == "pi" { return Double.pi }
                if name == "tau" { return Double.pi * 2 }
                if name == "e" { return M_E }
                guard peek() == .leftParen else { return nil }
                _ = advance()
                guard let argument = parseExpression(), advance() == .rightParen else { return nil }
                switch name {
                case "sqrt": return sqrt(argument)
                case "sin": return sin(argument)
                case "cos": return cos(argument)
                case "tan": return tan(argument)
                case "log": return log10(argument)
                case "ln": return log(argument)
                case "abs": return abs(argument)
                case "floor": return floor(argument)
                case "ceil": return ceil(argument)
                case "round": return argument.rounded()
                default: return nil
                }
            default:
                return nil
            }
        }
    }
}
