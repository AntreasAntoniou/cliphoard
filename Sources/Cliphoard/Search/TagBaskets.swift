import Foundation

/// A named collection of tags ("basket") that defines the classification
/// taxonomy. Switching basket re-tags clips from their cached vectors — no
/// re-embedding — so it's cheap.
struct TagBasket: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var tags: [String]

    /// Stable fingerprint of the tag set, for caching tag vectors.
    var fingerprint: String { "\(id):\(tags.count):\(HashingEmbedder.fnv1a(tags.joined(separator: "|")))" }
}

@MainActor
enum TagBaskets {
    static let general = TagBasket(id: "general", name: "General", tags: [
        "source code", "error message", "stack trace", "log line", "shell command",
        "terminal output", "git commit", "git diff", "python code", "javascript code",
        "swift code", "html markup", "css style", "sql query", "json data",
        "yaml config", "xml document", "markdown text", "regular expression", "api endpoint",
        "url link", "email address", "phone number", "postal address", "person name",
        "company name", "product name", "date", "time", "number",
        "currency amount", "percentage", "math equation", "uuid", "hash digest",
        "base64 blob", "ip address", "domain name", "file path", "directory path",
        "environment variable", "api key", "access token", "password", "username",
        "configuration", "dependency", "package version", "changelog", "license text",
        "legal clause", "contract term", "invoice", "receipt", "order number",
        "tracking number", "flight booking", "hotel booking", "meeting invite", "calendar event",
        "deadline", "reminder", "task item", "todo note", "project name",
        "ticket id", "issue report", "bug report", "feature request", "design note",
        "color value", "hex color", "font name", "image caption", "alt text",
        "translation", "quotation", "citation", "bibliography reference", "question",
        "answer", "definition", "instruction", "recipe", "ingredient list",
        "measurement", "coordinate", "country", "city", "language",
        "greeting", "signature", "title heading", "bullet list", "table data",
        "csv row", "spreadsheet cell", "math formula", "chemical formula", "miscellaneous text"
    ])

    static let developer = TagBasket(id: "developer", name: "Developer", tags: [
        "source code", "error message", "stack trace", "log line", "shell command",
        "terminal output", "git commit", "git diff", "pull request", "python code",
        "javascript code", "typescript code", "swift code", "rust code", "go code",
        "html markup", "css style", "sql query", "json data", "yaml config",
        "xml document", "markdown text", "regular expression", "api endpoint", "http header",
        "url link", "file path", "directory path", "environment variable", "api key",
        "access token", "uuid", "hash digest", "base64 blob", "ip address",
        "port number", "dependency", "package version", "dockerfile", "configuration",
        "function signature", "class definition", "import statement", "docstring", "test case"
    ])

    static let writing = TagBasket(id: "writing", name: "Writing & Research", tags: [
        "quotation", "citation", "bibliography reference", "footnote", "question",
        "answer", "definition", "instruction", "title heading", "subheading",
        "bullet list", "paragraph", "summary", "abstract", "thesis statement",
        "argument", "note", "idea", "todo note", "outline",
        "draft", "revision", "keyword", "tag", "author name",
        "book title", "journal article", "translation", "language", "glossary term",
        "url link", "email address", "date", "name", "place"
    ])

    static let business = TagBasket(id: "business", name: "Business & Finance", tags: [
        "invoice", "receipt", "order number", "tracking number", "purchase order",
        "currency amount", "price", "percentage", "tax id", "account number",
        "bank detail", "payment", "expense", "budget line", "quote",
        "proposal", "contract term", "legal clause", "company name", "person name",
        "job title", "postal address", "phone number", "email address", "meeting invite",
        "calendar event", "deadline", "product name", "sku", "discount code"
    ])

    static let everyday = TagBasket(id: "everyday", name: "Everyday", tags: [
        "person name", "phone number", "postal address", "email address", "url link",
        "date", "time", "reminder", "task item", "todo note",
        "shopping item", "recipe", "ingredient list", "measurement", "place",
        "city", "country", "password", "username", "wifi password",
        "confirmation number", "flight booking", "hotel booking", "directions", "note",
        "quote", "gift idea", "phone code"
    ])

    static let builtIn: [TagBasket] = [general, developer, writing, business, everyday]

    /// User-editable basket, persisted in UserDefaults (defaults to General's tags).
    static var custom: TagBasket {
        get {
            let tags = (UserDefaults.standard.array(forKey: "customTags") as? [String]) ?? general.tags
            return TagBasket(id: "custom", name: "Custom", tags: tags)
        }
        set { UserDefaults.standard.set(newValue.tags, forKey: "customTags") }
    }

    static var all: [TagBasket] { builtIn + [custom] }

    static var activeID: String {
        get { UserDefaults.standard.string(forKey: "activeBasket") ?? "general" }
        set { UserDefaults.standard.set(newValue, forKey: "activeBasket") }
    }

    static var active: TagBasket { all.first { $0.id == activeID } ?? general }
}
