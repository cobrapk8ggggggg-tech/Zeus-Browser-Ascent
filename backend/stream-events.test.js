const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createEventDecoder } = require('./stream-events');

test('every possible byte boundary preserves Arabic and split JSON events', () => {
    const expected = ['{"choices":[{"delta":{"content":"مرحبا 🌍"}}]}', '[DONE]'];
    const wire = Buffer.from(expected.map(x => `data: ${x}\r\n\r\n`).join(''));
    for (let i = 0; i <= wire.length; i++) {
        const events = [];
        const decoder = createEventDecoder(x => events.push(x));
        decoder.write(wire.subarray(0, i)); decoder.write(wire.subarray(i)); decoder.end();
        assert.deepEqual(events, expected, `boundary ${i}`);
    }
});
test('bytewise chunks, comments, multiple data fields and final unterminated event', () => {
    const events = [];
    const decoder = createEventDecoder(x => events.push(x));
    for (const byte of Buffer.from(': ping\ndata: one\ndata:two\n\ndata: أخير')) decoder.write(Buffer.from([byte]));
    decoder.end();
    assert.deepEqual(events, ['one\ntwo', 'أخير']);
});
