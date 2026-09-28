"""Vectorized inverse spline used when exporting the JP-Extra SDP to Core ML.

The original function uses boolean indexing and in-place writes. This form
computes all bins and selects valid values with tensor operations.
"""

from __future__ import annotations

import math

import torch
import torch.nn.functional as F


def coreml_piecewise_spline(
    inputs: torch.Tensor,
    unnormalized_widths: torch.Tensor,
    unnormalized_heights: torch.Tensor,
    unnormalized_derivatives: torch.Tensor,
    inverse: bool = False,
    tails: str | None = None,
    tail_bound: float = 1.0,
    min_bin_width: float = 1e-3,
    min_bin_height: float = 1e-3,
    min_derivative: float = 1e-3,
) -> tuple[torch.Tensor, torch.Tensor]:
    if not inverse or tails != "linear":
        raise ValueError("Core ML SDP spline supports inverse linear tails only")

    inside = (inputs >= -tail_bound) & (inputs <= tail_bound)
    safe_inputs = inputs.clamp(-tail_bound, tail_bound)
    constant = math.log(math.exp(1 - min_derivative) - 1)
    derivative_logits = F.pad(unnormalized_derivatives, (1, 1), value=constant)
    num_bins = unnormalized_widths.shape[-1]

    widths = min_bin_width + (1 - min_bin_width * num_bins) * F.softmax(
        unnormalized_widths, dim=-1
    )
    heights = min_bin_height + (1 - min_bin_height * num_bins) * F.softmax(
        unnormalized_heights, dim=-1
    )

    def endpoints(bin_sizes: torch.Tensor) -> torch.Tensor:
        first = torch.full_like(bin_sizes[..., :1], -tail_bound)
        middle = -tail_bound + 2 * tail_bound * torch.cumsum(bin_sizes, dim=-1)[..., :-1]
        last = torch.full_like(bin_sizes[..., :1], tail_bound)
        return torch.cat((first, middle, last), dim=-1)

    cumwidths = endpoints(widths)
    cumheights = endpoints(heights)
    widths = cumwidths[..., 1:] - cumwidths[..., :-1]
    heights = cumheights[..., 1:] - cumheights[..., :-1]
    derivatives = min_derivative + F.softplus(derivative_logits)

    index = (torch.sum(safe_inputs[..., None] >= cumheights, dim=-1) - 1).clamp(
        0, num_bins - 1
    )
    # PyTorch gather requires int64; the explicit int32 cast also helps Core ML.
    index = index.to(torch.int32).unsqueeze(-1)

    def pick(values: torch.Tensor) -> torch.Tensor:
        return values.gather(-1, index.to(torch.int64)).squeeze(-1)

    bin_start_width = pick(cumwidths)
    bin_width = pick(widths)
    bin_start_height = pick(cumheights)
    bin_height = pick(heights)
    delta = heights / widths
    bin_delta = pick(delta)
    left_derivative = pick(derivatives)
    right_derivative = pick(derivatives[..., 1:])

    displacement = safe_inputs - bin_start_height
    curvature = left_derivative + right_derivative - 2 * bin_delta
    a = displacement * curvature + bin_height * (bin_delta - left_derivative)
    b = bin_height * left_derivative - displacement * curvature
    c = -bin_delta * displacement
    discriminant = b * b - 4 * a * c
    root = (2 * c) / (
        -b - torch.sqrt(torch.maximum(discriminant, torch.zeros_like(discriminant)))
    )
    transformed = root * bin_width + bin_start_width

    theta = root * (1 - root)
    denominator = bin_delta + curvature * theta
    numerator = bin_delta.square() * (
        right_derivative * root.square()
        + 2 * bin_delta * theta
        + left_derivative * (1 - root).square()
    )
    logabsdet = 2 * torch.log(denominator) - torch.log(numerator)
    return (
        torch.where(inside, transformed, inputs),
        torch.where(inside, logabsdet, torch.zeros_like(inputs)),
    )
