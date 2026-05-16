/// Represents a single file entry in the YAML document.
#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
pub struct FileEntry {
    /// Relative path of the file (forward slashes).
    pub path: String,
    /// File content. `None` indicates a binary or unreadable file.
    pub content: Option<String>,
    /// ISO 8601 timestamp of the last modification time, or empty string if unknown.
    #[serde(default)]
    pub last_modified: String,
}

/// Produce a YAML document from a list of file entries.
///
/// Each file is rendered as a list item with:
///   - path: relative path (string)
///   - content: literal block scalar (`|`) for text files, `null` for binary
///
/// ```yaml
/// - path: foo/bar.md
///   content: |
///     Hello world
/// - path: image.png
///   content: null
/// ```
pub fn produce_yaml(files: &[FileEntry]) -> String {
    if files.is_empty() {
        return "# (no files)\n".to_string();
    }

    let indent = 2;
    let mut result = String::new();

    for file in files {
        // path line
        result.push_str("- path: ");
        result.push_str(&yaml_quote(&file.path));
        result.push('\n');

        // last_modified line
        if !file.last_modified.is_empty() {
            result.push_str(&spaces(indent));
            result.push_str(&format!("last_modified: {}\n", file.last_modified));
        }

        match &file.content {
            None => {
                // binary file – just note existence
                result.push_str(&spaces(indent));
                result.push_str("content: null\n");
            }
            Some(content) => {
                // text file – literal block scalar
                result.push_str(&spaces(indent));
                result.push_str("content: |\n");

                if content.is_empty() {
                    result.push_str(&spaces(indent * 2));
                    result.push_str("\"\"\n");
                } else {
                    for line in content.lines() {
                        result.push_str(&spaces(indent * 2));
                        result.push_str(line);
                        result.push('\n');
                    }
                }
            }
        }
    }

    result
}

/// Quote a YAML scalar value if needed.
/// Safe unquoted chars: alphanumerics, underscore, dot, slash, dash, space.
fn yaml_quote(value: &str) -> String {
    if value.is_empty() {
        return "\"\"".to_string();
    }
    if value
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '/' | '-' | ' '))
    {
        return value.to_string();
    }
    let escaped = value.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

/// Return a string of `count` spaces.
fn spaces(count: usize) -> String {
    " ".repeat(count)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_empty_files() {
        let result = produce_yaml(&[]);
        assert_eq!(result, "# (no files)\n");
    }

    #[test]
    fn test_text_file() {
        let files = vec![FileEntry {
            path: "hello.md".to_string(),
            content: Some("Hello\nWorld".to_string()),
            last_modified: String::new(),
        }];
        let result = produce_yaml(&files);
        assert_eq!(
            result,
            "- path: hello.md\n  content: |\n    Hello\n    World\n"
        );
    }

    #[test]
    fn test_binary_file() {
        let files = vec![FileEntry {
            path: "image.png".to_string(),
            content: None,
            last_modified: String::new(),
        }];
        let result = produce_yaml(&files);
        assert_eq!(result, "- path: image.png\n  content: null\n");
    }

    #[test]
    fn test_empty_content_file() {
        let files = vec![FileEntry {
            path: "empty.txt".to_string(),
            content: Some(String::new()),
            last_modified: String::new(),
        }];
        let result = produce_yaml(&files);
        assert_eq!(result, "- path: empty.txt\n  content: |\n    \"\"\n");
    }

    #[test]
    fn test_multiple_files() {
        let files = vec![
            FileEntry {
                path: "a.md".to_string(),
                content: Some("line1".to_string()),
                last_modified: String::new(),
            },
            FileEntry {
                path: "b.png".to_string(),
                content: None,
                last_modified: String::new(),
            },
        ];
        let result = produce_yaml(&files);
        assert!(result.contains("- path: a.md"));
        assert!(result.contains("- path: b.png"));
        assert!(result.contains("content: null"));
    }

    #[test]
    fn test_yaml_quote_already_safe() {
        assert_eq!(yaml_quote("hello.md"), "hello.md");
        assert_eq!(yaml_quote("foo/bar.txt"), "foo/bar.txt");
        assert_eq!(yaml_quote("my file.md"), "my file.md");
    }

    #[test]
    fn test_yaml_quote_needs_escaping() {
        assert_eq!(yaml_quote("file:name.md"), r#""file:name.md""#);
        assert_eq!(yaml_quote("\"quoted\""), r#""\"quoted\"""#);
    }

    #[test]
    fn test_file_with_last_modified() {
        let files = vec![FileEntry {
            path: "note.md".to_string(),
            content: Some("Hello".to_string()),
            last_modified: "2026-05-16T10:00:00Z".to_string(),
        }];
        let result = produce_yaml(&files);
        assert!(result.contains("last_modified: 2026-05-16T10:00:00Z"));
        assert!(result.contains("- path: note.md"));
        assert!(result.contains("content: |"));
    }
}
