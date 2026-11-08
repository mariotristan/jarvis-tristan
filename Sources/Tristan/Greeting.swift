import Foundation

/// What Tristan says when the app opens: a greeting for the time of day, the time and weekday, and a closing remark
/// for the day. The pieces are chosen from the date, so the same hour gives the same greeting and a different hour or
/// day gives another. "Welcome home, sir." is a line JARVIS says in the first Iron Man film; the rest is in its style.
enum Greeting {
    enum Part: Equatable { case morning, afternoon, evening, night }

    static func part(hour: Int) -> Part {
        switch hour {
        case 5..<12: return .morning
        case 12..<17: return .afternoon
        case 17..<22: return .evening
        default: return .night
        }
    }

    static let openers: [Part: [String]] = [
        .morning: ["Good morning, sir.", "Good morning, sir. I trust you slept well.", "Welcome back, sir. A fine morning to begin."],
        .afternoon: ["Good afternoon, sir.", "Welcome back, sir. The afternoon is yours.", "Good afternoon, sir. Shall we pick up where we left off?"],
        .evening: ["Good evening, sir.", "Welcome home, sir.", "Good evening, sir. The workshop is ready."],
        .night: ["Good evening, sir. It is rather late.", "Welcome home, sir. Burning the midnight oil, I see.", "Sir, the hour is late, but I am at your disposal."],
    ]

    static let closers = [
        "All systems are online and standing by.",
        "Every system is running at full capacity.",
        "I have taken the liberty of getting everything ready.",
        "Whenever you are ready, sir, I am at your service.",
    ]

    /// One more remark for a day of the week (1 = Sunday … 7 = Saturday, as `Calendar` numbers them).
    static let dayRemarks: [Int: [String]] = [
        1: ["A Sunday, sir. Even geniuses are allowed to rest."],
        2: ["A new week begins. I have cleared the decks."],
        3: ["Tuesday, sir. Momentum is building."],
        4: ["Midweek, sir. The summit is in sight."],
        5: ["Thursday, sir. Nearly there."],
        6: ["Friday, sir. The weekend is within reach."],
        7: ["Working on a Saturday, sir? I admire the dedication."],
    ]

    static func line(at date: Date = Date(), calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let weekday = calendar.component(.weekday, from: date)
        let seed = (calendar.ordinality(of: .day, in: .year, for: date) ?? 0) * 24 + hour
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "h:mm a"
        let time = formatter.string(from: date)
        formatter.dateFormat = "EEEE"
        let day = formatter.string(from: date)

        let opening = pick(openers[part(hour: hour)] ?? [], seed)
        let closing = pick(closers + (dayRemarks[weekday] ?? []), seed / 3)
        return "\(opening) It is \(time) on \(day). \(closing)"
    }

    static let facts = [
        "A day on Venus is longer than its year.",
        "Honey never spoils. Edible honey has been found in ancient Egyptian tombs.",
        "Octopuses have three hearts and blue blood.",
        "The Eiffel Tower grows a few centimetres taller in summer, because heat expands the iron.",
        "Bananas are berries, but strawberries are not.",
        "Light from the Sun takes about eight minutes to reach the Earth.",
        "The first computer bug was a real moth, found in a Harvard computer in 1947.",
        "Wombats produce cube-shaped droppings.",
        "There are more possible games of chess than atoms in the observable universe.",
        "Lightning is about five times hotter than the surface of the Sun.",
    ]

    static let kidsFacts = [
        "Did you know? Octopuses have three hearts!",
        "Did you know? A day on Venus is longer than a whole year there!",
        "Did you know? Bananas are berries, but strawberries are not!",
        "Did you know? Butterflies taste with their feet!",
        "Did you know? Honey never goes bad, even after thousands of years!",
        "Did you know? A group of flamingos is called a flamboyance!",
        "Did you know? Wombats make cube-shaped poop!",
        "Did you know? The Sun is so big that a million Earths could fit inside it!",
        "Did you know? Sea otters hold hands when they sleep, so they do not drift apart!",
        "Did you know? A snail can sleep for up to three years!",
    ]

    /// One fact for the app opening, chosen at random (or by `seed`, for tests).
    static func fact(kids: Bool, seed: Int? = nil) -> String {
        let list = kids ? kidsFacts : facts
        return list[abs(seed ?? Int.random(in: 0..<list.count)) % list.count]
    }

    private static func pick(_ options: [String], _ seed: Int) -> String {
        options.isEmpty ? "" : options[abs(seed) % options.count]
    }
}
