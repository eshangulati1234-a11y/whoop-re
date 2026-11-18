import unittest
from evaluate_health import evaluate
class EvaluationTests(unittest.TestCase):
    def test_missing_reference_is_not_accuracy(self):
        result = evaluate([dict(kind='hr',id='a',value='70')],[])
        self.assertIsNone(result['hr']['mean_absolute_error'])
        self.assertEqual(result['hr']['unmatched_predictions'],1)
    def test_error_and_missing(self):
        result = evaluate([dict(kind='hr',id='a',value='75')],[dict(kind='hr',id='a',value='70'),dict(kind='hr',id='b',value='80')])['hr']
        self.assertEqual(result['mean_absolute_error'],5)
        self.assertEqual(result['missing'],1)
    def test_duplicates_and_nan(self):
        row = dict(kind='energy',id='a',value='nan')
        with self.assertRaises(ValueError): evaluate([row,row],[])
        with self.assertRaises(ValueError): evaluate([row],[dict(row,value='20')])
if __name__ == '__main__': unittest.main()
