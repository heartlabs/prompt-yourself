/**
 *
 * @typedef {Object} Message
 * @property {'system'|'user'|'assistant'} role
 * @property {string} content
 */

/**
 * Creates a chat completion via the DeepSeek API.
 *
 * @param {Object} options
 * @param {string} options.apiKey - DeepSeek API key
 * @param {Message[]} options.messages - Conversation messages
 * @param {AbortSignal} [options.signal] - Optional abort signal
 * @param {number} [options.maxTokens=1000] - Maximum tokens in the response
 * @returns {Promise<string>} The assistant's reply
 */
export async function chatCompletion({ apiKey, messages, signal, maxTokens = 1000 }) {
  const response = await fetch('https://api.deepseek.com/chat/completions', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: 'deepseek-chat',
      messages,
      max_tokens: maxTokens,
    }),
    signal,
  });

  if (!response.ok) {
    const errBody = await response.text().catch(() => '');
    throw new Error(`DeepSeek API error (${response.status}): ${errBody}`);
  }

  const data = await response.json();
  return data.choices[0].message.content;
}

/**
 * Builds the initial messages array: system prompt + the document.
 *
 * @param {string} systemPrompt - The system prompt text
 * @param {string} documentContent - The file content to reference
 * @returns {Message[]}
 */
export function buildInitialMessages(systemPrompt, documentContent) {
  return [
    { role: 'system', content: systemPrompt },
    {
      role: 'user',
      content: `Here is the document to reference:\n\n${documentContent}`,
    },
  ];
}
