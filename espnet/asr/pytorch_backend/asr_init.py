"""Finetuning methods."""

import logging
import os
import torch

from collections import OrderedDict

from espnet.asr.asr_utils import get_model_conf
from espnet.asr.asr_utils import torch_load

from espnet.nets.asr_interface import ASRInterface
from espnet.nets.mt_interface import MTInterface
from espnet.nets.tts_interface import TTSInterface

from espnet.utils.dynamic_import import dynamic_import


def transfer_verification(model_state_dict, partial_state_dict, modules):
    """Verify tuples (key, shape) for input model modules match specified modules.

    Args:
        model_state_dict (OrderedDict): the initial model state_dict
        partial_state_dict (OrderedDict): the trained model state_dict
        modules (list): specified module list for transfer

    Return:
        (boolean): allow transfer

    """
    partial_modules = []
    for key_p, value_p in partial_state_dict.items():
        if any(key_p.startswith(m) for m in modules):
            if value_p.shape == model_state_dict[key_p].shape:
                partial_modules += [(key_p, value_p.shape)]
    return len(partial_modules) > 0


def get_partial_state_dict(model_state_dict, modules):
    """Create state_dict with specified modules matching input model modules.

    Note that get_partial_lm_state_dict is used if a LM specified.

    Args:
        model_state_dict (OrderedDict): trained model state_dict
        modules (list): specified module list for transfer

    Return:
        new_state_dict (OrderedDict): the updated state_dict

    """
    new_state_dict = OrderedDict()

    for key, value in model_state_dict.items():
        if any(key.startswith(m) for m in modules):
            new_state_dict[key] = value

    return new_state_dict


def get_partial_state_dict_dual_decoders(model_state_dict, modules):
    """Create state_dict with specified modules matching input model modules.

    Note that get_partial_lm_state_dict is used if a LM specified.

    Args:
        model_state_dict (OrderedDict): trained model state_dict
        modules (list): specified module list for transfer

    Return:
        new_state_dict (OrderedDict): the updated state_dict

    """
    new_state_dict = OrderedDict()
    new_modules = []
    pretrained_keys = list(model_state_dict.keys())
    submodules = ['embed', 'after_norm', 'output_layer', 'self_attn', 'src_attn', 
                'feed_forward', 'norm1', 'norm2', 'norm3', 'dropout']

    for key, value in model_state_dict.items():
        if any(key.startswith(m) for m in modules):
            key = key.replace('decoders', 'dual_decoders')
            if '_asr' not in key:
                new_mod = key.replace('decoder.', 'dual_decoder.')
            else:
                new_mod = key.replace('decoder_asr.', 'dual_decoder.')
                for k in submodules:
                    new_mod = new_mod.replace(k, k+'_asr')
            new_state_dict[new_mod] = value
            new_modules += [new_mod]

    return new_state_dict, new_modules


def get_partial_lm_state_dict(model_state_dict, modules):
    """Create compatible ASR state_dict from model_state_dict (LM).

    The keys for specified modules are modified to match ASR decoder modules keys.

    Args:
        model_state_dict (OrderedDict): trained model state_dict
        modules (list): specified module list for transfer

    Return:
        new_state_dict (OrderedDict): the updated state_dict
        new_mods (list): the updated module list

    """
    new_state_dict = OrderedDict()
    new_modules = []

    for key, value in list(model_state_dict.items()):
        if key == "predictor.embed.weight" and "predictor.embed." in modules:
            new_key = "dec.embed.weight"
            new_state_dict[new_key] = value
            new_modules += [new_key]
        elif "predictor.rnn." in key and "predictor.rnn." in modules:
            new_key = "dec.decoder." + key.split("predictor.rnn.", 1)[1]
            new_state_dict[new_key] = value
            new_modules += [new_key]

    return new_state_dict, new_modules


def filter_modules(model_state_dict, modules):
    """Filter non-matched modules in module_state_dict.

    Args:
        model_state_dict (OrderedDict): trained model state_dict
        modules (list): specified module list for transfer

    Return:
        new_mods (list): the update module list

    """
    new_mods = []
    incorrect_mods = []

    mods_model = list(model_state_dict.keys())
    for mod in modules:
        if any(key.startswith(mod) for key in mods_model):
            new_mods += [mod]
        else:
            incorrect_mods += [mod]

    if incorrect_mods:
        logging.warning("module(s) %s don\'t match or (partially match) "
                        "available modules in model.", incorrect_mods)
        logging.warning('for information, the existing modules in model are:')
        logging.warning('%s', mods_model)

    return new_mods


def filter_modules_dual_decoders(model_state_dict, modules):
    """Filter non-matched modules in module_state_dict.

    Args:
        model_state_dict (OrderedDict): trained model state_dict
        modules (list): specified module list for transfer

    Return:
        new_mods (list): the update module list

    """
    new_mods = []
    incorrect_mods = []

    mods_model = list(model_state_dict.keys())
    new_mods = []

    # Create tuple of (k_pretrained, k_new)
    for new_mod in modules:
        new_mod = new_mod.replace('dual_decoders', 'decoders')
        if '_asr' not in new_mod:
            mod = new_mod.replace('dual_decoder.', 'decoder.')
        else:
            mod = new_mod.replace('_asr', '').replace('dual_decoder.', 'decoder_asr.')

        if any(key.startswith(mod) for key in mods_model):
            new_mods += [mod]
        else:
            incorrect_mods += [mod]

    if incorrect_mods:
        logging.warning("module(s) %s don\'t match or (partially match) "
                        "available modules in model.", incorrect_mods)
        logging.warning('for information, the existing modules in model are:')
        logging.warning('%s', mods_model)

    return new_mods


def load_trained_model(model_path):
    """Load the trained model for recognition.

    Args:
        model_path (str): Path to model.***.best

    """
    idim, odim, train_args = get_model_conf(
        model_path, os.path.join(os.path.dirname(model_path), 'model.json'))

    logging.warning('reading model parameters from ' + model_path)

    if hasattr(train_args, "model_module"):
        model_module = train_args.model_module
    else:
        model_module = "espnet.nets.pytorch_backend.e2e_asr:E2E"
    model_class = dynamic_import(model_module)
    model = model_class(idim, odim, train_args)

    torch_load(model_path, model)

    return model, train_args


def get_trained_model_state_dict(model_path):
    """Extract the trained model state dict for pre-initialization.

    Args:
        model_path (str): Path to model.***.best

    Return:
        model.state_dict() (OrderedDict): the loaded model state_dict
        (bool): Boolean defining whether the model is an LM

    """
    conf_path = os.path.join(os.path.dirname(model_path), 'model.json')
    if 'rnnlm' in model_path:
        logging.warning('reading model parameters from %s', model_path)

        return torch.load(model_path), True

    idim, odim, args = get_model_conf(model_path, conf_path)

    logging.warning('reading model parameters from ' + model_path)

    if hasattr(args, "model_module"):
        model_module = args.model_module
    else:
        model_module = "espnet.nets.pytorch_backend.e2e_asr:E2E"

    logging.info(f'Loading pre-trained model...')
    model_class = dynamic_import(model_module)
    model = model_class(idim, odim, args)

    torch_load(model_path, model)
    logging.info(f'Pre-trained model is loaded.')
    assert isinstance(model, MTInterface) or \
        isinstance(model, ASRInterface) or \
        isinstance(model, TTSInterface)

    return model.state_dict(), False


def load_trained_modules(idim, odim, args, interface=ASRInterface):
    """Load model encoder or/and decoder modules with ESPNET pre-trained model(s).

    Args:
        idim (int): initial input dimension.
        odim (int): initial output dimension.
        args (Namespace): The initial model arguments.
        interface (Interface): ASRInterface or STInterface or TTSInterface.

    Return:
        model (torch.nn.Module): The model with pretrained modules.

    """
    enc_model_path = args.enc_init
    dec_model_path = args.dec_init
    enc_modules = args.enc_init_mods
    dec_modules = args.dec_init_mods
    dual_modules = None

    model_class = dynamic_import(args.model_module)
    main_model = model_class(idim, odim, args)
    assert isinstance(main_model, interface)
    logging.info('| Before loading pretrained models: {}'.format(sum(p.sum().item() for p in main_model.parameters())))

    main_state_dict = main_model.state_dict()

    logging.warning('model(s) found for pre-initialization')
    for model_path, modules in [(enc_model_path, enc_modules),
                                (dec_model_path, dec_modules)]:
        if model_path is not None:
            if os.path.isfile(model_path):
                model_state_dict, is_lm = get_trained_model_state_dict(model_path)

                if all(mod.startswith('dual_decoder') for mod in modules):
                    dual_modules = modules
                    modules = filter_modules_dual_decoders(model_state_dict, modules)
                else:
                    modules = filter_modules(model_state_dict, modules)

                if is_lm:
                    partial_state_dict, modules = get_partial_lm_state_dict(model_state_dict, modules)
                else:
                    if dual_modules is not None:
                        partial_state_dict, modules = get_partial_state_dict_dual_decoders(model_state_dict, modules)
                    else:
                        partial_state_dict = get_partial_state_dict(model_state_dict, modules)

                    if partial_state_dict:
                        if transfer_verification(main_state_dict, partial_state_dict, modules):
                            logging.warning('loading %s from model: %s', list(set(['.'.join(m.split('.')[:2]) for m in modules])), model_path)
                            
                            for k in partial_state_dict.keys():
                                logging.warning('override %s' % k)
                            main_state_dict.update(partial_state_dict)
                        else:
                            logging.warning('modules %s in model %s don\'t match your training config',
                                            modules, model_path)
                        # Random check
                        k1 = 'decoder.decoders.0.src_attn.linear_v.weight'
                        k2 = 'decoder_asr.decoders.0.src_attn.linear_v.weight'
                        if k1 in partial_state_dict and k2 in partial_state_dict:
                            a = partial_state_dict[k1]
                            b = partial_state_dict[k2]
                            logging.info('TO'*20)
                            logging.info(f'diff = {torch.norm(a - b)}')
                            logging.info(f'a is b = {a is b}')
                    
            else:
                logging.warning('model was not found : %s', model_path)

    main_model.load_state_dict(main_state_dict)

    logging.info('| After loading pretrained models: {}'.format(sum(p.sum().item() for p in main_model.parameters())))

    return main_model
