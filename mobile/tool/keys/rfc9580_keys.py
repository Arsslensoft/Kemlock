"""Copies the armored sample keys of RFC 9580 appendices A.3 to A.5 out of
the RFC's text, without its page breaks and indentation.

Run once on 2026-11-15 to make test/fixtures/keys/rfc9580; never rerun over it.

    python3 -I tool/keys/rfc9580_keys.py <rfc9580.txt> <output dir>
"""
import re
import sys

text = open(sys.argv[1]).read()
out = sys.argv[2]
# Drop the page footers and headers between pages.
text = re.sub(r'\n[^\n]*\[Page \d+\]\n\x0c\n[^\n]*\n', '\n', text)


def block(section, next_section, kind):
    start = text.rindex(section)
    end = text.index(next_section, start)
    part = text[start:end]
    begin = part.index(f'-----BEGIN PGP {kind} KEY BLOCK-----')
    finish = part.index(f'-----END PGP {kind} KEY BLOCK-----') + len(f'-----END PGP {kind} KEY BLOCK-----')
    lines = [line.strip() for line in part[begin:finish].split('\n')]
    return "\n".join(lines) + "\n"


files = {
    'v6-public.asc': block('A.3.  Sample Version 6 Certificate', 'A.3.1.', 'PUBLIC'),
    'v6-secret.asc': block('A.4.  Sample Version 6 Secret Key', 'A.5.  Sample Locked', 'PRIVATE'),
    'v6-locked-secret.asc': block('A.5.  Sample Locked Version 6 Secret Key', 'A.5.1.', 'PRIVATE'),
}
for name, content in files.items():
    open(f'{out}/{name}', 'w').write(content)
    print(name, len(content.splitlines()), 'lines')
