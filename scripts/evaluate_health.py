#!/usr/bin/env python3
"""Compare held-out reference CSVs. No model fitting or automatic coefficient changes.
Columns: kind,id,value,start,end. kind: hr, sleep, workout, energy.
For hr/energy value is BPM/kcal. For sleep/workout start/end are Unix seconds.
IDs must independently identify matching observations; missing IDs are reported.
"""
import argparse, csv, json, math, statistics

def evaluate(predictions, references):
    def index(rows):
        result = {}
        for row in rows:
            key = (row['kind'], row['id'])
            if key in result:
                raise ValueError('Duplicate observation: ' + str(key))
            result[key] = row
        return result
    predicted, reference = index(predictions), index(references)
    result = {}
    for kind in ('hr', 'sleep', 'workout', 'energy'):
        keys = {key for key in reference if key[0] == kind}
        found = {key for key in predicted if key[0] == kind}
        matched = sorted(keys & found)
        errors = []
        for key in matched:
            fields = ('start', 'end') if kind in ('sleep', 'workout') else ('value',)
            for field in fields:
                error = float(predicted[key][field]) - float(reference[key][field])
                if not math.isfinite(error):
                    raise ValueError('Nonfinite measurement')
                errors.append(error)
        result[kind] = dict(reference_count=len(keys), matched=len(matched), missing=len(keys-found), unmatched_predictions=len(found-keys),
                            mean_absolute_error=statistics.mean(map(abs, errors)) if errors else None,
                            bias=statistics.mean(errors) if errors else None,
                            units='seconds' if kind in ('sleep','workout') else 'bpm' if kind == 'hr' else 'kcal')
    return result

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('predictions'); parser.add_argument('references')
    args = parser.parse_args()
    with open(args.predictions, newline='') as p, open(args.references, newline='') as r:
        print(json.dumps(evaluate(list(csv.DictReader(p)), list(csv.DictReader(r))), indent=2))
