/**
 * Produces a YAML document representing a collection of files (flat or nested).
 *
 * Each file is rendered as a list item with:
 *   - path:  relative path (string)
 *   - content: literal block scalar (|) for text files, null for binary
 *
 * @param {Array<{path:string, content:string|null}>} files
 * @param {Object} [options]
 * @param {number} [options.indent=2]  Number of spaces per indentation level
 * @returns {string}  YAML string
 */
export function produceYaml(files, options = {}) {
  const indent = options.indent ?? 2;

  if (!files || files.length === 0) {
    return "# (no files)\n";
  }

  const lines = [];

  for (const file of files) {
    // path line
    lines.push("- path: " + yamlQuote(file.path));

    if (file.content === null) {
      // binary file – just note existence
      lines.push(spaces(indent) + "content: null");
    } else {
      // text file – literal block scalar
      lines.push(spaces(indent) + "content: |");

      const body = typeof file.content === "string" ? file.content : String(file.content);
      const bodyLines = body.split("\n");

      if (bodyLines.length === 0 || (bodyLines.length === 1 && bodyLines[0] === "")) {
        // empty file – still emit an empty content marker
        lines.push(spaces(indent * 2) + '""');
      } else {
        for (const line of bodyLines) {
          lines.push(spaces(indent * 2) + line);
        }
      }
    }
  }

  return lines.join("\n") + "\n";
}

/**
 * Quote a YAML scalar value if needed.
 * Safe unquoted chars: alphanumerics, underscore, dot, slash, dash, space.
 */
function yamlQuote(value) {
  if (typeof value !== "string") return String(value);
  if (/^[a-zA-Z0-9_./\u{80}-\u{10FFFF} -]+$/u.test(value)) {
    return value;
  }
  const escaped = value.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  return '"' + escaped + '"';
}

/** Return a string of `count` spaces. */
function spaces(count) {
  let s = "";
  for (let i = 0; i < count; i++) s += " ";
  return s;
}
