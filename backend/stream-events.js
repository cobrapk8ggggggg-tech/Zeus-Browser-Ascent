const { StringDecoder } = require('node:string_decoder');

// HTTP chunks may split a UTF-8 character or a JSON event at any byte.
function createEventDecoder(onData) {
    const decoder = new StringDecoder('utf8');
    let pending = '';
    let fields = [];
    function line(value) {
        if (value === '') {
            if (fields.length) onData(fields.join('\n'));
            fields = [];
        } else if (value === 'data' || value.startsWith('data:')) {
            fields.push(value === 'data' ? '' : value.slice(5).replace(/^ /, ''));
        }
    }
    function drain(final = false) {
        let match;
        while ((match = /\r\n|\r|\n/.exec(pending))) {
            if (!final && match[0] === '\r' && match.index === pending.length - 1) break;
            line(pending.slice(0, match.index));
            pending = pending.slice(match.index + match[0].length);
        }
        if (final && pending) { line(pending); pending = ''; }
        if (final) line('');
    }
    return {
        write(chunk) { pending += decoder.write(chunk); drain(); },
        end() { pending += decoder.end(); drain(true); }
    };
}
module.exports = { createEventDecoder };
