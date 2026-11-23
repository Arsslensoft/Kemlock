"""Trims NIST ACVP-Server internalProjection.json files to a few cases of
ML-KEM-768 and ML-DSA-65, keeping NIST's field names and test case ids.

Run once on 2026-11-15 to make test/fixtures/keys/acvp; never rerun over it.

    python3 -I tool/keys/trim_acvp.py <acvp download dir> <output dir>

The download dir has kemkey/, kemencap/ and dsakey/, each holding the
internalProjection.json of ML-KEM-keyGen-FIPS203, ML-KEM-encapDecap-FIPS203
and ML-DSA-keyGen-FIPS204.
"""
import json
import sys

src, out = sys.argv[1], sys.argv[2]


def load(name):
    return json.load(open(f'{src}/{name}/internalProjection.json'))


def group(doc, parameter_set, function=None):
    for g in doc['testGroups']:
        if g['parameterSet'] == parameter_set and g.get('function') == function:
            return g
    raise KeyError((parameter_set, function))


def pick(tests, ids, fields):
    by_id = {t['tcId']: t for t in tests}
    return [{f: by_id[i][f] for f in ['tcId', *fields] if f in by_id[i]} for i in ids]


key_gen = load('kemkey')
encap = load('kemencap')
kem = {
    'source': 'https://github.com/usnistgov/ACVP-Server, gen-val/json-files/ML-KEM-keyGen-FIPS203 and '
              'ML-KEM-encapDecap-FIPS203 (internalProjection.json, vsId 42), ML-KEM-768 cases only',
    'keyGen': pick(group(key_gen, 'ML-KEM-768')['tests'], [26, 27, 28], ['d', 'z', 'ek', 'dk']),
    'encapsulation': pick(group(encap, 'ML-KEM-768', 'encapsulation')['tests'], [26, 27, 28], ['ek', 'm', 'c', 'k']),
    'decapsulation': pick(group(encap, 'ML-KEM-768', 'decapsulation')['tests'], [86, 88, 91], ['dk', 'c', 'k', 'reason']),
    'decapsulationKeyCheck': pick(group(encap, 'ML-KEM-768', 'decapsulationKeyCheck')['tests'], [126, 128], ['dk', 'testPassed', 'reason']),
    'encapsulationKeyCheck': pick(group(encap, 'ML-KEM-768', 'encapsulationKeyCheck')['tests'], [136, 137], ['ek', 'testPassed', 'reason']),
}
json.dump(kem, open(f'{out}/ml-kem-768.json', 'w'), indent=1)
open(f'{out}/ml-kem-768.json', 'a').write('\n')

dsa = {
    'source': 'https://github.com/usnistgov/ACVP-Server, gen-val/json-files/ML-DSA-keyGen-FIPS204 '
              '(internalProjection.json, vsId 42), ML-DSA-65 cases only',
    'keyGen': pick(group(load('dsakey'), 'ML-DSA-65')['tests'], [26, 27, 28], ['seed', 'pk', 'sk']),
}
json.dump(dsa, open(f'{out}/ml-dsa-65.json', 'w'), indent=1)
open(f'{out}/ml-dsa-65.json', 'a').write('\n')
