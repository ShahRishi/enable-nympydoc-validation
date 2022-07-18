# Copyright (c) 2022, NVIDIA CORPORATION.

import textwrap
from dataclasses import dataclass
from typing import Any, Callable, Dict, Optional, Union


@dataclass
class Option:
    default: Any
    value: Any
    description: str
    validator: Callable


_OPTIONS: Dict[str, Option] = {}


def _register_option(
    name: str, default_value: Any, description: str, validator: Callable
):
    """Register an option.

    Parameters
    ----------
    name : str
        The name of the option.
    default_value : Any
        The default value of the option.
    description : str
        A text description of the option.
    validator : Callable
        Called on the option value to check its validity. Should raise an
        error if the value is invalid.

    """
    validator(default_value)
    _OPTIONS[name] = Option(
        default_value, default_value, description, validator
    )


def get_option(name: str) -> Any:
    """Get the value of option.

    Parameters
    ----------
    key : str
        The name of the option.

    Returns
    -------
    The value of the option.
    """
    return _OPTIONS[name].value


def set_option(name: str, val: Any):
    """Set the value of option.

    Raises ``ValueError`` if the provided value is invalid.

    Parameters
    ----------
    name : str
        The name of the option.
    val : Any
        The value to set.
    """
    option = _OPTIONS[name]
    option.validator(val)
    option.value = val


def _build_option_description(name, opt):
    return (
        f"{name}:\n"
        f"\t{opt.description}\n"
        f"\t[Default: {opt.default}] [Current: {opt.value}]"
    )


def describe_option(name: Optional[str] = None):
    """Prints a specific option description or all option descriptions.

    If `name` is unspecified, prints all available option descriptions.

    Parameters
    ----------
    name : Optional[str]
        The name of the option.
    """
    s = ""
    if name is None:
        s = "\n".join(
            _build_option_description(name, opt)
            for name, opt in _OPTIONS.items()
        )
    else:
        s = _build_option_description(name, _OPTIONS[name])
    print(s)


_register_option(
    "default_integer_bitwidth",
    64,
    "Default integer bitwidth when inferring integer column or scalars."
    "Influences integer column bitwidth for csv, json readers if unspecified "
    "and integer column bitwidth constructed from python scalar and lists. "
    "Valid values are 32 or 64.",
    lambda x: x in [32, 64],
)

_register_option(
    "default_float_bitwidth",
    64,
    "Default float bitwidth when inferring float column or scalars."
    "Influences float column bitwidth for csv, json readers if unspecified "
    "and float column bitwidth constructed from python scalar and lists. "
    "Valid values are 32 or 64.",
    lambda x: x in [32, 64],
)
