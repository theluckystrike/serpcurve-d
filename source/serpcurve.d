/**
 * serpcurve - fit a search click-through curve to your own measured data,
 * then use it to convert ranking positions into expected clicks.
 *
 * The library ships no built-in "industry average" CTR table on purpose.
 * Every number it returns is derived from the (position, impressions, clicks)
 * rows you hand it - typically straight out of a Search Console export - so a
 * result can always be traced back to a measurement you own.
 *
 * Model: ctr(p) = ctr1 * p^(-alpha), a two-parameter power law fitted by
 * impression-weighted least squares in log-log space.
 *
 * Dependency-free, @safe, and covered by unit tests.
 */
module serpcurve;

import std.math : pow, log, exp, isFinite, fabs;

/// One measured row: the average position a query/page held, the impressions
/// it accumulated at that position, and the clicks it earned.
struct Observation
{
    double position;    /// average SERP position, 1.0 = top organic result
    double impressions; /// impressions accumulated
    double clicks;      /// clicks earned
}

/// A fitted power-law click-through curve: ctr(p) = ctr1 * p^(-alpha).
struct CtrCurve
{
    double ctr1;  /// modelled click-through rate at position 1 (0..1)
    double alpha; /// decay exponent; larger = steeper drop down the page
}

/// Thrown when the input rows cannot support a fit.
class CurveFitException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// True when a row can take part in a log-log fit: finite, positive
/// impressions and clicks, and a position at or below the first result.
bool isFittable(in Observation o) @safe pure nothrow @nogc
{
    if (!isFinite(o.position) || !isFinite(o.impressions) || !isFinite(o.clicks))
        return false;
    if (o.position < 1.0 || o.impressions <= 0.0 || o.clicks <= 0.0)
        return false;
    return o.clicks <= o.impressions;
}

/// Measured click-through rate of a single row, or 0 when it has no impressions.
double observedCtr(in Observation o) @safe pure nothrow @nogc
{
    if (!isFinite(o.impressions) || o.impressions <= 0.0)
        return 0.0;
    if (!isFinite(o.clicks) || o.clicks <= 0.0)
        return 0.0;
    return o.clicks / o.impressions;
}

/// Modelled click-through rate at `position`, clamped to the 0..1 interval.
double ctrAt(in CtrCurve c, double position) @safe pure nothrow @nogc
{
    if (!isFinite(position) || position < 1.0)
        return 0.0;
    if (!isFinite(c.ctr1) || !isFinite(c.alpha))
        return 0.0;
    const v = c.ctr1 * pow(position, -c.alpha);
    if (!isFinite(v) || v <= 0.0)
        return 0.0;
    return v > 1.0 ? 1.0 : v;
}

/// Expected clicks for `impressions` served at `position` under the curve.
double expectedClicks(in CtrCurve c, double impressions, double position) @safe pure nothrow @nogc
{
    if (!isFinite(impressions) || impressions <= 0.0)
        return 0.0;
    return impressions * ctrAt(c, position);
}

/// Clicks gained (positive) or lost (negative) by moving the same impression
/// pool from `fromPosition` to `toPosition`.
double clickDelta(in CtrCurve c, double impressions, double fromPosition, double toPosition)
    @safe pure nothrow @nogc
{
    const before = expectedClicks(c, impressions, fromPosition);
    const after = expectedClicks(c, impressions, toPosition);
    return after - before;
}

/// The position at which the curve predicts `targetCtr`. Returns 0 when the
/// target is unreachable (non-positive, or above the curve's own ceiling).
double positionForCtr(in CtrCurve c, double targetCtr) @safe pure nothrow @nogc
{
    if (!isFinite(targetCtr) || targetCtr <= 0.0 || targetCtr > 1.0)
        return 0.0;
    if (!isFinite(c.ctr1) || c.ctr1 <= 0.0 || !isFinite(c.alpha) || c.alpha <= 0.0)
        return 0.0;
    const p = exp((log(c.ctr1) - log(targetCtr)) / c.alpha);
    if (!isFinite(p) || p < 1.0)
        return 0.0;
    return p;
}

/// Impression-weighted average position across the rows; 0 when there are none.
double blendedPosition(in Observation[] rows) @safe pure nothrow @nogc
{
    double num = 0.0, den = 0.0;
    foreach (const ref o; rows)
    {
        if (!isFinite(o.position) || !isFinite(o.impressions) || o.impressions <= 0.0)
            continue;
        num += o.position * o.impressions;
        den += o.impressions;
    }
    return den > 0.0 ? num / den : 0.0;
}

/// Aggregate click-through rate of the rows: total clicks over total impressions.
double aggregateCtr(in Observation[] rows) @safe pure nothrow @nogc
{
    double clicks = 0.0, impressions = 0.0;
    foreach (const ref o; rows)
    {
        if (!isFinite(o.clicks) || !isFinite(o.impressions) || o.impressions <= 0.0)
            continue;
        clicks += o.clicks > 0.0 ? o.clicks : 0.0;
        impressions += o.impressions;
    }
    return impressions > 0.0 ? clicks / impressions : 0.0;
}

/**
 * Fit ctr(p) = ctr1 * p^(-alpha) by impression-weighted least squares on
 * ln(ctr) against ln(position).
 *
 * Throws: CurveFitException when fewer than two fittable rows survive, or when
 * every surviving row sits at the same position (the slope is then undefined).
 */
CtrCurve fitCtrCurve(in Observation[] rows) @safe pure
{
    double sw = 0.0, sx = 0.0, sy = 0.0;
    size_t used = 0;
    foreach (const ref o; rows)
    {
        if (!isFittable(o))
            continue;
        sw += o.impressions;
        sx += o.impressions * log(o.position);
        sy += o.impressions * log(o.clicks / o.impressions);
        ++used;
    }
    if (used < 2 || sw <= 0.0)
        throw new CurveFitException("serpcurve: need at least two fittable rows");

    const meanX = sx / sw;
    const meanY = sy / sw;
    double sxx = 0.0, sxy = 0.0;
    foreach (const ref o; rows)
    {
        if (!isFittable(o))
            continue;
        const dx = log(o.position) - meanX;
        const dy = log(o.clicks / o.impressions) - meanY;
        sxx += o.impressions * dx * dx;
        sxy += o.impressions * dx * dy;
    }
    if (!isFinite(sxx) || sxx <= 1e-12 * sw)
        throw new CurveFitException("serpcurve: rows do not span two distinct positions");

    const slope = sxy / sxx;
    const curve = CtrCurve(exp(meanY - slope * meanX), -slope);
    if (!isFinite(curve.ctr1) || !isFinite(curve.alpha))
        throw new CurveFitException("serpcurve: fit did not converge to finite parameters");
    return curve;
}

/// Impression-weighted coefficient of determination of the fit, measured in
/// log space where the fit was performed. 1.0 is a perfect fit; values at or
/// below 0 mean the curve explains no more than the weighted mean does.
double logFitQuality(in CtrCurve c, in Observation[] rows) @safe pure nothrow @nogc
{
    double sw = 0.0, sy = 0.0;
    foreach (const ref o; rows)
    {
        if (!isFittable(o))
            continue;
        sw += o.impressions;
        sy += o.impressions * log(o.clicks / o.impressions);
    }
    if (sw <= 0.0)
        return 0.0;
    const mean = sy / sw;
    double ssRes = 0.0, ssTot = 0.0;
    foreach (const ref o; rows)
    {
        if (!isFittable(o))
            continue;
        const y = log(o.clicks / o.impressions);
        const yHat = log(c.ctr1) - c.alpha * log(o.position);
        ssRes += o.impressions * (y - yHat) * (y - yHat);
        ssTot += o.impressions * (y - mean) * (y - mean);
    }
    if (!isFinite(ssTot) || ssTot <= 0.0)
        return 0.0;
    return 1.0 - ssRes / ssTot;
}

// ---------------------------------------------------------------- unit tests

@safe unittest // a curve evaluated at position 1 returns ctr1, and decays after
{
    const c = CtrCurve(0.30, 1.2);
    assert(fabs(ctrAt(c, 1.0) - 0.30) < 1e-12);
    assert(ctrAt(c, 5.0) < ctrAt(c, 2.0));
    assert(ctrAt(c, 0.5) == 0.0);
    assert(ctrAt(c, double.nan) == 0.0);
}

@safe unittest // ctr is clamped into 0..1 even for an absurd ctr1
{
    const c = CtrCurve(4.0, 0.5);
    assert(ctrAt(c, 1.0) == 1.0);
    assert(ctrAt(c, 100.0) <= 1.0);
}

@safe unittest // the fit recovers parameters it generated
{
    const truth = CtrCurve(0.28, 1.35);
    Observation[] rows;
    foreach (i; 1 .. 11)
    {
        const p = cast(double) i;
        const imps = 1000.0;
        rows ~= Observation(p, imps, imps * ctrAt(truth, p));
    }
    const fitted = fitCtrCurve(rows);
    assert(fabs(fitted.ctr1 - truth.ctr1) < 1e-6);
    assert(fabs(fitted.alpha - truth.alpha) < 1e-6);
    assert(logFitQuality(fitted, rows) > 0.999);
}

@safe unittest // too few usable rows, or a single position, are refused
{
    bool threwOnEmpty = false;
    try
        cast(void) fitCtrCurve([]);
    catch (CurveFitException)
        threwOnEmpty = true;
    assert(threwOnEmpty);

    bool threwOnFlat = false;
    Observation[] flat = [Observation(3.0, 100.0, 10.0), Observation(3.0, 200.0, 20.0)];
    try
        cast(void) fitCtrCurve(flat);
    catch (CurveFitException)
        threwOnFlat = true;
    assert(threwOnFlat);
}

@safe unittest // rows with impossible values are ignored rather than poisoning the fit
{
    assert(!isFittable(Observation(0.5, 100.0, 10.0)));
    assert(!isFittable(Observation(2.0, 100.0, 400.0)));
    assert(!isFittable(Observation(2.0, 0.0, 0.0)));
    assert(isFittable(Observation(2.0, 100.0, 10.0)));
}

@safe unittest // expected clicks and the delta between two positions agree
{
    const c = CtrCurve(0.30, 1.2);
    const gain = clickDelta(c, 10_000.0, 8.0, 3.0);
    assert(gain > 0.0);
    const manual = expectedClicks(c, 10_000.0, 3.0) - expectedClicks(c, 10_000.0, 8.0);
    assert(fabs(gain - manual) < 1e-9);
    assert(clickDelta(c, 10_000.0, 3.0, 8.0) < 0.0);
}

@safe unittest // positionForCtr inverts ctrAt
{
    const c = CtrCurve(0.30, 1.2);
    const p = positionForCtr(c, ctrAt(c, 6.0));
    assert(fabs(p - 6.0) < 1e-9);
    assert(positionForCtr(c, 0.0) == 0.0);
    assert(positionForCtr(c, 0.9) == 0.0); // above the curve's position-1 ceiling
}

@safe unittest // blended position and aggregate ctr weight by impressions
{
    Observation[] rows = [
        Observation(2.0, 900.0, 90.0),
        Observation(12.0, 100.0, 1.0)
    ];
    assert(fabs(blendedPosition(rows) - 3.0) < 1e-12);
    assert(fabs(aggregateCtr(rows) - 0.091) < 1e-12);
    assert(blendedPosition([]) == 0.0);
    assert(aggregateCtr([]) == 0.0);
}

@safe unittest // observedCtr guards against empty and impossible rows
{
    assert(fabs(observedCtr(Observation(1.0, 200.0, 50.0)) - 0.25) < 1e-12);
    assert(observedCtr(Observation(1.0, 0.0, 5.0)) == 0.0);
    assert(observedCtr(Observation(1.0, 100.0, 0.0)) == 0.0);
}
