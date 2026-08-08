# serpcurve

Fit a search click-through curve to your own measured data, then use it to turn
ranking positions into expected clicks.

The library deliberately ships **no built-in "industry average" CTR table**. A
published curve is somebody else's SERP, with their brands, their intent mix and
their ad load. Hand `serpcurve` the `(position, impressions, clicks)` rows you
already have — a Search Console export is exactly the right shape — and every
number it hands back traces to a measurement you own.

Written for the pipeline behind [toolsthatrank.com](https://toolsthatrank.com/),
which refuses to publish a figure it cannot check against a source.

## Model

    ctr(p) = ctr1 * p^(-alpha)

Two parameters, fitted by impression-weighted least squares on `ln(ctr)` against
`ln(position)`. Weighting by impressions stops a single 3-impression row at
position 2 from dominating the fit.

## Usage

```d
import serpcurve;

Observation[] rows = [
    Observation(1.8,  9_100, 2_410),
    Observation(4.2,  6_300,   540),
    Observation(11.6, 4_800,    62),
];

auto curve = fitCtrCurve(rows);          // CtrCurve(ctr1, alpha)
auto quality = logFitQuality(curve, rows);

auto ctr = ctrAt(curve, 3.0);            // modelled CTR at position 3
auto gain = clickDelta(curve, 4_800, 11.6, 4.0);  // clicks won by that move
auto p = positionForCtr(curve, 0.05);    // where the curve predicts a 5% CTR
```

`fitCtrCurve` throws `CurveFitException` rather than returning a guess when the
rows cannot support a fit: fewer than two usable rows, or every usable row
sitting at one position, so the slope is undefined.

## API

| function | what it returns |
| --- | --- |
| `fitCtrCurve(rows)` | the impression-weighted power-law fit |
| `logFitQuality(curve, rows)` | weighted R² in the log space where the fit ran |
| `ctrAt(curve, position)` | modelled CTR, clamped to `0..1` |
| `expectedClicks(curve, impressions, position)` | impressions × modelled CTR |
| `clickDelta(curve, impressions, from, to)` | clicks gained or lost by a move |
| `positionForCtr(curve, ctr)` | the inverse of `ctrAt` |
| `blendedPosition(rows)` | impression-weighted average position |
| `aggregateCtr(rows)` | total clicks ÷ total impressions |
| `observedCtr(row)` | one row's measured CTR |
| `isFittable(row)` | whether a row can enter the fit at all |

Rows that cannot be true are dropped rather than silently distorting the result:
a position below 1, non-positive impressions, or more clicks than impressions.

## Tests

```
dub test --compiler=ldc2
```

Nine `unittest` blocks, including a round trip that generates rows from a known
curve and checks the fit recovers both parameters, and a check that
`positionForCtr` inverts `ctrAt`.

## License

MIT.
