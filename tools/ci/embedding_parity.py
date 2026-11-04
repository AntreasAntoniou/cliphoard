"""Pure finite-vector checks, importable without NumPy or a native runtime."""
import math

def vector(value):
    if not isinstance(value, (list, tuple)) or len(value) != 384:
        raise ValueError('embedding_dimension')
    if any(type(x) not in (int, float) or not math.isfinite(x) for x in value):
        raise ValueError('embedding_nonfinite')
    norm = math.sqrt(math.fsum(x*x for x in value))
    if not math.isfinite(norm) or norm <= 1e-12:
        raise ValueError('embedding_zero_norm')
    return norm

def compare(reference, actual, threshold=0.999):
    a, b = vector(reference), vector(actual)
    cosine = math.fsum(x*y for x, y in zip(reference, actual))/(a*b)
    if not math.isfinite(cosine) or cosine < threshold:
        raise ValueError('embedding_parity')
    return {'dimension':384, 'referenceNorm':a, 'actualNorm':b, 'cosine':cosine}
