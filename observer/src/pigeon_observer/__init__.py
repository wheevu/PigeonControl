"""pigeon_observer: offline observer and evaluation package for PigeonControl.

This package is the *offline* lane. It consumes datasets produced by the
simulation/generator and scores models. It does not participate in the live
UDP runtime protocol and never feeds state back into the simulation.

Integration contract (implemented by sibling observer modules, imported
lazily by the CLI and evaluation entry points):

- ``pigeon_observer.data``
    convert_raw_run, build_dataset_manifest, validate_dataset,
    ObserverSequenceDataset
- ``pigeon_observer.models``
    ObserverModelConfig, ObserverModel
- ``pigeon_observer.training``
    train_model, load_checkpoint (and config helpers)

Those submodules are intentionally not imported at package import time so that
``import pigeon_observer`` (and ``import pigeon_observer.cli`` for ``--help``)
succeeds even before the sibling modules are present.
"""

__version__ = "0.1.0"

from . import evaluation  # owned here; its imports are lazy/cheap

__all__ = ["__version__", "evaluation"]
