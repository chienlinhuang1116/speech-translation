#!/bin/bash

# Copyright 2019 Kyoto University (Hirofumi Inaguma)
#  Apache 2.0  (http://www.apache.org/licenses/LICENSE-2.0)

. ./path.sh || exit 1;
. ./cmd.sh || exit 1;

# general configuration
backend=pytorch # chainer or pytorch
stage=        # start from -1 if you need to start from data download
stop_stage=
ngpu=0          # number of gpus ("0" uses cpu, otherwise use gpu)
nj=16           # number of parallel jobs for decoding
debugmode=4
dumpdir=dump    # directory to dump full features
N=0             # number of minibatches to be used (mainly for debugging). "0" uses all minibatches.
verbose=1       # verbose option
resume=         # Resume the training from snapshot
seed=1          # seed to generate random number
mode=debug
# feature configuration
do_delta=false

preprocess_config=specaug.yaml
train_config=
decode_config=

# decoding parameter
trans_model= # set a model to be used for decoding: 'model.acc.best' or 'model.loss.best'

# model average related (only for transformer)
n_average=5                  # the number of ST models to be averaged
use_valbest_average=true     # if true, the validation `n_average`-best ST models will be averaged.
                             # if false, the last `n_average` ST models will be averaged.

# pre-training related
asr_model=
mt_model=

# preprocessing related
src_case=lc.rm
tgt_case=tc
# tc: truecase
# lc: lowercase
# lc.rm: lowercase with punctuation removal

# Set this to somewhere where you want to put your data, or where
# someone else has already put it.
must_c=$WORK/Data/MUSTC_v1.0

# target language related
# tgt_lang="de_es_fr_nl_it_pt_ro_ru"
tgt_lang=
# you can choose from de, es, fr, it, nl, pt, ro, ru
# if you want to train the multilingual model, segment languages with _ as follows:
# e.g., tgt_lang="de_es_fr"
# if you want to use all languages, set tgt_lang="all"

# bpemode (unigram or bpe)
nbpe=8000
bpemode=bpe

trans_set=

# exp tag
tag="" # tag for managing experiments.

. utils/parse_options.sh || exit 1;

echo "| tgt_lang: ${tgt_lang}"
echo "| tag: ${tag}"
echo "| nbpe = ${nbpe}"
echo "| ngpu = ${ngpu}"
echo "| train_config: ${train_config}"
echo "| decode_config: ${decode_config}"
echo "| preprocess_config: ${preprocess_config}"

# Set bash to 'debug' mode, it will exit on :
# -e 'error', -u 'undefined variable', -o ... 'error in pipeline', -x 'print commands',
set -e
set -u
set -o pipefail

train_set=train_sp.en-${tgt_lang}.${tgt_lang}
train_dev=dev.en-${tgt_lang}.${tgt_lang}
# trans_set=""
# for lang in $(echo ${tgt_lang} | tr '_' ' '); do
#     trans_set+="tst-COMMON.en-${lang}.${lang} tst-HE.en-${lang}.${lang} "
# done 
echo "| trans sets: ${trans_set}"

if [ ${stage} -le -1 ] && [ ${stop_stage} -ge -1 ]; then
    echo "***** stage -1: Data Download *****"
    for lang in $(echo ${tgt_lang} | tr '_' ' '); do
        local/download_and_untar.sh ${must_c} ${lang}
    done
fi

if [ ${stage} -le 0 ] && [ ${stop_stage} -ge 0 ]; then
    ### Task dependent. You have to make data the following preparation part by yourself.
    ### But you can utilize Kaldi recipes in most cases
    echo "***** stage 0: Data Preparation *****"
    for lang in $(echo ${tgt_lang} | tr '_' ' '); do
        local/data_prep.sh ${must_c} ${lang}
    done
fi

feat_tr_dir=${dumpdir}/${train_set}/delta${do_delta}; mkdir -p ${feat_tr_dir}
feat_dt_dir=${dumpdir}/${train_dev}/delta${do_delta}; mkdir -p ${feat_dt_dir}
if [ ${stage} -le 1 ] && [ ${stop_stage} -ge 1 ]; then
    ### Task dependent. You have to design training and dev sets by yourself.
    ### But you can utilize Kaldi recipes in most cases
    echo "***** stage 1: Feature Generation *****"
    fbankdir=fbank
    # Generate the fbank features; by default 80-dimensional fbanks with pitch on each frame
    for lang in $(echo ${tgt_lang} | tr '_' ' '); do
        for x in train.en-${tgt_lang} dev.en-${tgt_lang} tst-COMMON.en-${tgt_lang} tst-HE.en-${tgt_lang}; do
            steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 32 --write_utt2num_frames true \
                data/${x} exp/make_fbank/${x} ${fbankdir}
        done
    done

    # speed-perturbed
    utils/perturb_data_dir_speed.sh 0.9 data/train.en-${tgt_lang} data/temp1.${tgt_lang}
    utils/perturb_data_dir_speed.sh 1.0 data/train.en-${tgt_lang} data/temp2.${tgt_lang}
    utils/perturb_data_dir_speed.sh 1.1 data/train.en-${tgt_lang} data/temp3.${tgt_lang}
    utils/combine_data.sh --extra-files utt2uniq data/train_sp.en-${tgt_lang} \
        data/temp1.${tgt_lang} data/temp2.${tgt_lang} data/temp3.${tgt_lang}
    rm -r data/temp1.${tgt_lang} data/temp2.${tgt_lang} data/temp3.${tgt_lang}
    steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 32 --write_utt2num_frames true \
        data/train_sp.en-${tgt_lang} exp/make_fbank/train_sp.en-${tgt_lang} ${fbankdir}
    for lang in en ${tgt_lang}; do
        awk -v p="sp0.9-" '{printf("%s %s%s\n", $1, p, $1);}' data/train.en-${tgt_lang}/utt2spk > data/train_sp.en-${tgt_lang}/utt_map
        utils/apply_map.pl -f 1 data/train_sp.en-${tgt_lang}/utt_map <data/train.en-${tgt_lang}/text.tc.${lang} >data/train_sp.en-${tgt_lang}/text.tc.${lang}
        utils/apply_map.pl -f 1 data/train_sp.en-${tgt_lang}/utt_map <data/train.en-${tgt_lang}/text.lc.${lang} >data/train_sp.en-${tgt_lang}/text.lc.${lang}
        utils/apply_map.pl -f 1 data/train_sp.en-${tgt_lang}/utt_map <data/train.en-${tgt_lang}/text.lc.rm.${lang} >data/train_sp.en-${tgt_lang}/text.lc.rm.${lang}
        awk -v p="sp1.0-" '{printf("%s %s%s\n", $1, p, $1);}' data/train.en-${tgt_lang}/utt2spk > data/train_sp.en-${tgt_lang}/utt_map
        utils/apply_map.pl -f 1 data/train_sp.en-${tgt_lang}/utt_map <data/train.en-${tgt_lang}/text.tc.${lang} >>data/train_sp.en-${tgt_lang}/text.tc.${lang}
        utils/apply_map.pl -f 1 data/train_sp.en-${tgt_lang}/utt_map <data/train.en-${tgt_lang}/text.lc.${lang} >>data/train_sp.en-${tgt_lang}/text.lc.${lang}
        utils/apply_map.pl -f 1 data/train_sp.en-${tgt_lang}/utt_map <data/train.en-${tgt_lang}/text.lc.rm.${lang} >>data/train_sp.en-${tgt_lang}/text.lc.rm.${lang}
        awk -v p="sp1.1-" '{printf("%s %s%s\n", $1, p, $1);}' data/train.en-${tgt_lang}/utt2spk > data/train_sp.en-${tgt_lang}/utt_map
        utils/apply_map.pl -f 1 data/train_sp.en-${tgt_lang}/utt_map <data/train.en-${tgt_lang}/text.tc.${lang} >>data/train_sp.en-${tgt_lang}/text.tc.${lang}
        utils/apply_map.pl -f 1 data/train_sp.en-${tgt_lang}/utt_map <data/train.en-${tgt_lang}/text.lc.${lang} >>data/train_sp.en-${tgt_lang}/text.lc.${lang}
        utils/apply_map.pl -f 1 data/train_sp.en-${tgt_lang}/utt_map <data/train.en-${tgt_lang}/text.lc.rm.${lang} >>data/train_sp.en-${tgt_lang}/text.lc.rm.${lang}
    done

    # Divide into source and target languages
    for x in train_sp.en-${tgt_lang} dev.en-${tgt_lang} tst-COMMON.en-${tgt_lang} tst-HE.en-${tgt_lang}; do
        local/divide_lang.sh ${x} ${tgt_lang}
    done

    for x in train_sp.en-${tgt_lang} dev.en-${tgt_lang}; do
        # remove utt having more than 3000 frames
        # remove utt having more than 400 characters
        for lang in ${tgt_lang} en; do
            remove_longshortdata.sh --maxframes 3000 --maxchars 400 data/${x}.${lang} data/${x}.${lang}.tmp
        done

        # Match the number of utterances between source and target languages
        # extract common lines
        cut -f 1 -d " " data/${x}.en.tmp/text > data/${x}.${tgt_lang}.tmp/reclist1
        cut -f 1 -d " " data/${x}.${tgt_lang}.tmp/text > data/${x}.${tgt_lang}.tmp/reclist2
        comm -12 data/${x}.${tgt_lang}.tmp/reclist1 data/${x}.${tgt_lang}.tmp/reclist2 > data/${x}.en.tmp/reclist

        for lang in ${tgt_lang} en; do
            reduce_data_dir.sh data/${x}.${lang}.tmp data/${x}.en.tmp/reclist data/${x}.${lang}
            utils/fix_data_dir.sh --utt_extra_files "text.tc text.lc text.lc.rm" data/${x}.${lang}
        done
        rm -rf data/${x}.*.tmp
    done

    # compute global CMVN
    compute-cmvn-stats scp:data/${train_set}/feats.scp data/${train_set}/cmvn.ark

    # dump features for training
    if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d ${feat_tr_dir}/storage ]; then
      utils/create_split_dir.pl \
          /export/b{14,15,16,17}/${USER}/espnet-data/egs/must_c/st1/dump/${train_set}/delta${do_delta}/storage \
          ${feat_tr_dir}/storage
    fi
    if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d ${feat_dt_dir}/storage ]; then
      utils/create_split_dir.pl \
          /export/b{14,15,16,17}/${USER}/espnet-data/egs/must_c/st1/dump/${train_dev}/delta${do_delta}/storage \
          ${feat_dt_dir}/storage
    fi
    dump.sh --cmd "$train_cmd" --nj 80 --do_delta $do_delta \
        data/${train_set}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/${train_set} ${feat_tr_dir}
    dump.sh --cmd "$train_cmd" --nj 32 --do_delta $do_delta \
        data/${train_dev}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/${train_dev} ${feat_dt_dir}
    for ttask in ${trans_set}; do
        feat_trans_dir=${dumpdir}/${ttask}/delta${do_delta}; mkdir -p ${feat_trans_dir}
        dump.sh --cmd "$train_cmd" --nj 32 --do_delta $do_delta \
            data/${ttask}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/trans/${ttask} \
            ${feat_trans_dir}
    done
fi

# Multilingual related parameters
lang_pairs=""
lang_count=0
for lang in $(echo ${tgt_lang} | tr '_' ' '); do
    lang_pairs+="en-${lang},"
    lang_count=$((lang_count + 1))
done
lang_pairs=$(echo ${lang_pairs::-1})
echo "| number of target languages: ${lang_count}"
echo "| language pairs: ${lang_pairs}"

if (( $lang_count == 8 )); then
    suffix="_v2"
elif (( $lang_count == 2 )); then
    suffix="_v2.1"
else
    suffix=""
fi
dict=data/lang_1spm/${train_set}_${bpemode}${nbpe}_units_${tgt_case}${suffix}.txt
nlsyms=data/lang_1spm/${train_set}_non_lang_syms_${tgt_case}${suffix}.txt
nlsyms_tmp=data/lang_1spm/${train_set}_non_lang_syms_${tgt_case}_tmp${suffix}.txt
bpemodel=data/lang_1spm/${train_set}_${bpemode}${nbpe}_${tgt_case}${suffix}
echo "| bpe model: ${bpemodel}"
if [ ${stage} -le 2 ] && [ ${stop_stage} -ge 2 ]; then
    ### Task dependent. You have to check non-linguistic symbols used in the corpus.
    echo "***** stage 2: Dictionary and Json Data Preparation *****"
    mkdir -p data/lang_1spm/

    echo "make a non-linguistic symbol list for all languages"
    if [ -f ${nlsyms_tmp} ]; then
        echo "remove existing non-lang files"
        rm ${nlsyms_tmp}
    fi
    for lang in $(echo ${tgt_lang} | tr '_' ' '); do
        grep sp1.0 data/train_sp.en-${lang}.${lang}/text.${tgt_case} | cut -f 2- -d' ' | grep -o -P '&[^;]*;' >> ${nlsyms_tmp}
    done
    
    cat ${nlsyms_tmp} | sort | uniq > ${nlsyms}
    rm ${nlsyms_tmp}
    cat ${nlsyms}

    echo "make a joint source and target dictionary"
    # echo "<unk> 1" > ${dict} # <unk> must be 1, 0 will be used for "blank" in CTC
    # add more special symbols for later use
    # special_symbols="<unk> 1; <s> 2; </s> 3; <pad> 4; <TRANS> 5; <RECOG> 6; <DELAY> 7"
    special_symbols="<unk> 1"
    i=2
    all_langs=$(echo ${tgt_lang}"_en" | tr '_' ' ')
    all_langs_sorted=$(echo ${all_langs[*]}| tr " " "\n" | sort -n | tr "\n" " ")
    echo "all langs sorted: ${all_langs_sorted}"
    for lang in $(echo "${all_langs_sorted}" | tr '_' ' '); do
        special_symbols+="; <2${lang}> ${i}"
        i=$((i + 1))
    done
    sed "s/; /\n/g" <<< ${special_symbols} > ${dict}
    echo "special symbols"
    cat ${dict}

    offset=$(wc -l < ${dict})
    echo "| offset= ${offset}"
    input_path=data/lang_1spm/input_en-${tgt_lang}.${tgt_lang}.${tgt_case}${suffix}.txt
    if [ -f ${input_path} ]; then
        echo "remove existing input text file"
        rm ${input_path}
    fi

    for lang in $(echo ${tgt_lang} | tr '_' ' '); do
        # grep sp1.0 data/train_sp.en-${lang}.${lang}/text.${tgt_case} | cut -f 2- -d' ' | grep -v -e '^\s*$' >> ${input_path}
        cat data/lang_1spm/input_en-${lang}.${lang}.${tgt_case}.txt >> ${input_path}
    done
    spm_train --user_defined_symbols="$(tr "\n" "," < ${nlsyms})" --input=${input_path} --vocab_size=${nbpe} --model_type=${bpemode} --model_prefix=${bpemodel} --input_sentence_size=100000000 --character_coverage=1.0
    spm_encode --model=${bpemodel}.model --output_format=piece < ${input_path} | tr ' ' '\n' | sort | uniq | awk -v offset=${offset} '{print $0 " " NR+offset}' >> ${dict}
    echo "| number of tokens in dictionary: $(wc -l ${dict})"

    echo "make json files"
    for lang in $(echo ${tgt_lang} | tr '_' ' '); do
        train_set_lang=train_sp.en-${lang}.${lang}
        train_dev_lang=dev.en-${lang}.${lang}
        feat_tr_dir_lang=${dumpdir}/${train_set_lang}/delta${do_delta}
        feat_dt_dir_lang=${dumpdir}/${train_dev_lang}/delta${do_delta}

        data2json.sh --nj 16 --feat ${feat_tr_dir_lang}/feats.scp --text data/${train_set_lang}/text.${tgt_case} --bpecode ${bpemodel}.model --lang ${lang} \
            data/${train_set_lang} ${dict} > ${feat_tr_dir_lang}/data-en-${lang}_${bpemode}${nbpe}.${tgt_case}${suffix}.json
        data2json.sh --feat ${feat_dt_dir_lang}/feats.scp --text data/${train_dev_lang}/text.${tgt_case} --bpecode ${bpemodel}.model --lang ${lang} \
            data/${train_dev_lang} ${dict} > ${feat_dt_dir_lang}/data-en-${lang}_${bpemode}${nbpe}.${tgt_case}${suffix}.json
        
        trans_set_lang="tst-COMMON.en-${lang}.${lang} tst-HE.en-${lang}.${lang}"
        for ttask in ${trans_set_lang}; do
            feat_trans_dir=${dumpdir}/${ttask}/delta${do_delta}
            data2json.sh --feat ${feat_trans_dir}/feats.scp --text data/${ttask}/text.${tgt_case} --bpecode ${bpemodel}.model --lang ${lang} \
                data/${ttask} ${dict} > ${feat_trans_dir}/data-en-${lang}_${bpemode}${nbpe}.${tgt_case}${suffix}.json
        done

        # update json (add source references)
        for x in ${train_set_lang} ${train_dev_lang}; do
            feat_dir=${dumpdir}/${x}/delta${do_delta}
            data_dir=data/$(echo ${x} | cut -f 1 -d ".").en-${lang}.en
            update_json.sh --text ${data_dir}/text.${src_case} --bpecode ${bpemodel}.model \
                ${feat_dir}/data-en-${lang}_${bpemode}${nbpe}.${tgt_case}${suffix}.json ${data_dir} ${dict}
        done
        for ttask in ${trans_set_lang}; do
            echo "add source references to ${ttask}"
            feat_trans_dir=${dumpdir}/${ttask}/delta${do_delta}
            data_dir=data/$(echo ${ttask} | cut -f 1 -d ".").en-${lang}.en
            update_json.sh --text ${data_dir}/text.${src_case} --bpecode ${bpemodel}.model \
                ${feat_trans_dir}/data-en-${lang}_${bpemode}${nbpe}.${tgt_case}${suffix}.json ${data_dir} ${dict}
        done
    done
fi

# NOTE: skip stage 3: LM Preparation

if [ -z ${tag} ]; then
    expname=${train_set}_${tgt_case}_${backend}_$(basename ${train_config%.*})_${bpemode}${nbpe}
    if ${do_delta}; then
        expname=${expname}_delta
    fi
    if [ -n "${preprocess_config}" ]; then
        expname=${expname}_$(basename ${preprocess_config%.*})
    fi
    if [ -n "${asr_model}" ]; then
        expname=${expname}_asrtrans
    fi
    if [ -n "${mt_model}" ]; then
        expname=${expname}_mttrans
    fi
else
    # expname=${train_set}_${tgt_case}_${backend}_${tag}
    expname=${tag} # get the name as the tag only
fi
# Folder to save experiment results

# Directory includes sym links to all pairs
if [[ $tag == *"debug"* ]]; then
    echo "Run on debug folder ..."
    main_dir=$WORK/Data/MUSTC_debug_v2/${tgt_lang}
    expdir=$SCRATCH/Experiments_espnet/debug/${expname}
    tensorboard_dir=tensorboard_debug/${expname}
else
    echo "Run on all data ..."
    main_dir=$WORK/Data/MUSTC_espnet_v2/${tgt_lang}
    expdir=$SCRATCH/Experiments_espnet/exp/${expname}
    tensorboard_dir=tensorboard/${expname}
fi
mkdir -p ${expdir}
echo "| main_dir= ${main_dir}"
echo "| expdir= ${expdir}"

# Data input folders
train_json_dir=${main_dir}/train_sp
val_json_dir=${main_dir}/dev
dict=${main_dir}/lang_1spm/train_sp.en-${tgt_lang}.${tgt_lang}_bpe8000_units_tc${suffix}.txt

echo "| train_json_dir: ${train_json_dir}"
echo "| val_json_dir: ${val_json_dir}"
echo "| dictionary: ${dict}"

if [ ${stage} -le 4 ] && [ ${stop_stage} -ge 4 ]; then
    echo "***** stage 4: Network Training *****"

    # Find the last snapshot
    resume_dir=$expdir/results
    if [ -d $resume_dir ]; then
        ckpt_nums=$(ls $resume_dir | grep snapshot | sed 's/[^0-9]*//g' | sed 's/\n/" "/g')
        last_ep=$(echo "${ckpt_nums[*]}" | sort -nr | head -n1)
        echo "Resume training from the last snapshot ${resume_dir}/snapshot.iter.${last_ep}"
        resume=${resume_dir}/snapshot.iter.${last_ep}
    fi

    ${cuda_cmd} --gpu ${ngpu} ${expdir}/train.log \
        st_train.py \
        --lang-pairs ${lang_pairs} \
        --config ${train_config} \
        --preprocess-conf ${preprocess_config} \
        --lang-pairs ${lang_pairs} \
        --ngpu ${ngpu} \
        --backend ${backend} \
        --outdir ${expdir}/results \
        --tensorboard-dir ${tensorboard_dir} \
        --debugmode ${debugmode} \
        --dict ${dict} \
        --debugdir ${expdir} \
        --minibatches ${N} \
        --seed ${seed} \
        --verbose ${verbose} \
        --resume $resume \
        --train-json ${train_json_dir} \
        --valid-json ${val_json_dir} \
        --report-bleu \
        --report-wer
    
    echo "Log output is saved in ${expdir}/train.log"
fi

if [ ${stage} -le 5 ] && [ ${stop_stage} -ge 5 ]; then
    echo "***** stage 5: Decoding *****"
    if [[ $(get_yaml.py ${train_config} model-module) = *transformer* ]]; then
        # Average ST models
        if [ -z ${trans_model} ]; then
            if ${use_valbest_average}; then
                trans_model=model.val${n_average}.avg.best
                opt="--log ${expdir}/results/use_average_valbest_${n_average}/log"
            else
                trans_model=model.last${n_average}.avg.best
                opt="--log ${expdir}/results/use_average_last_${n_average}/log"
            fi
            echo "Averaging checkpoints ..."
            average_checkpoints.py \
                ${opt} \
                --backend ${backend} \
                --snapshots ${expdir}/results/snapshot.iter.* \
                --out ${expdir}/results/${trans_model} \
                --num ${n_average}
        fi
    fi
    echo "| trans_model: ${trans_model}"

    num_threads=96
    # nj=$(( num_threads / lang_count ))
    # nj=$(( num_threads / (lang_count * 2) ))
    nj=96
    if [[ $tag == *"debug"* ]]; then
        nj=1 # for debug
    fi
    echo "| njobs = ${nj}"
    pids=() # initialize pids

    # # for debug
    # trans_set=""
    # for lang in $(echo ${tgt_lang} | tr '_' ' '); do
    #     trans_set+="train_sp.en-${lang}.${lang} "
    # done

    for ttask in ${trans_set}; do
        split=$(cut -d'.' -f1 <<< ${ttask})
        lg_pair=$(cut -d'.' -f2 <<< ${ttask})
        echo "| split: ${split}"
        echo "| language pair: ${lg_pair}"
    
    (
        decode_config_lg_pair=${decode_config}.${lg_pair}.yaml
        decode_dir=decode_$(basename ${train_config%.*})_$(basename ${decode_config})_${split}_${lg_pair}_${trans_model}
        # feat_trans_dir=${main_dir}/train_sp # for debug
        feat_trans_dir=${main_dir}/${split}
        echo "| decode_dir: ${decode_dir}"
        echo "| feat_trans_dir: ${feat_trans_dir}"

        if [ ! -f "${feat_trans_dir}/split${nj}utt_${tgt_lang}/${lg_pair}.${nj}.json" ]; then
            # split data
            splitjson.py --parts ${nj} --tgt_lang ${tgt_lang} ${feat_trans_dir}/${lg_pair}.json
            echo "Finished splitting json file."
        else
            echo "json file has been already split."
        fi

        #### use CPU for decoding
        ngpu=0

        echo "Start decoding..."
        ${decode_cmd} JOB=1:${nj} ${expdir}/${decode_dir}/log/decode.JOB.log \
            st_trans.py \
            --config ${decode_config_lg_pair} \
            --ngpu ${ngpu} \
            --backend ${backend} \
            --batchsize 0 \
            --trans-json ${feat_trans_dir}/split${nj}utt_${tgt_lang}/${lg_pair}.JOB.json \
            --result-label ${expdir}/${decode_dir}/data.JOB.json \
            --model ${expdir}/results/${trans_model} \
            --verbose ${verbose}

        echo "Compute bleu using bpemodel: ${bpemodel}.model..."
        score_bleu.sh --case ${tgt_case} --bpe ${nbpe} --bpemodel ${bpemodel}.model \
            ${expdir}/${decode_dir} ${tgt_lang} ${dict}

        # local/score_sclite.sh --case ${src_case} --bpe ${nbpe} --bpemodel ${bpemodel}.model --wer true \
        #     ${expdir}/${decode_dir} ${dict}
    ) &
    pids+=($!) # store background pids
    done
    i=0; for pid in "${pids[@]}"; do wait ${pid} || ((++i)); done
    [ ${i} -gt 0 ] && echo "$0: ${i} background jobs are failed." && false
    echo "Finished."
fi