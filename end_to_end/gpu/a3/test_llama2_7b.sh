#!/bin/bash

# This file is both an integration test that runs once a day on a A3 and documentation for how to get started with Llama2-7b

# The flow of this file is as follows:
# 1. Download the checkpoint from Meta (https://llama.meta.com/llama-downloads/) in your local directory. Convert this PyTorch checkpoint into Orbax checkpoint format for use in MaxText.
# 2. Run training of Llama2-7b.
# 3. Run decoding from the trained checkpoint.


set -ex
idx=$(date +%Y-%m-%d-%H-%M)

# Non-Googlers please remember to point `BASE_OUTPUT_DIRECTORY` to a GCS bucket that you own, this bucket will store all the files generated by MaxText during a run
export BASE_OUTPUT_DIRECTORY=gs://runner-maxtext-logs
export ASYNC_CHECKPOINTING=false

# We install torch CPU because the checkpoint conversion script MaxText/llama_or_mistral_ckpt.py does not need a TPU/GPU
pip install torch --index-url https://download.pytorch.org/whl/cpu

# We define a var for the path to the Meta checkpoint. Non-Googlers please remember to update the source `META_CHECKPOINT_PATH` to the GCS bucket where you have your Meta checkpoint
export META_CHECKPOINT_PATH=gs://maxtext-llama/llama2-7b/meta-ckpt

# In the following command, we are copying Meta's checkpoint into a local directory `tmp`.
# You can use a different local directory than /tmp/, if you do so, please use the same local path for `base-model-path` when running `python3 MaxText/llama_or_mistral_ckpt.py`
gcloud storage cp -r ${META_CHECKPOINT_PATH} /tmp/

# `CONVERTED_CHECKPOINT_PATH` is the path to the GCS bucket where we want to save our converted (Orbax) checkpoint. Non-Googlers please remember to point `CONVERTED_CHECKPOINT_PATH` to a GCS bucket that you own
export CONVERTED_CHECKPOINT_PATH=gs://maxtext-llama/test/${idx}/decode-ckpt-maxtext-gpu

#Next, run the conversion script `MaxText/llama_or_mistral_ckpt.py` to convert Meta's PyTorch checkpoint in `base-model-path` and save the new converted (Orbax) checkpoint in the `maxtext-model-path`
python3 MaxText/llama_or_mistral_ckpt.py --base-model-path /tmp/meta-ckpt --model-size llama2-7b --maxtext-model-path ${CONVERTED_CHECKPOINT_PATH}

# We define `CONVERTED_CHECKPOINT` to refer to the checkpoint subdirectory exactly inside `CONVERTED_CHECKPOINT_PATH`. This way it is easier to use this path in the `train.py` and `decode.py` commands
export CONVERTED_CHECKPOINT=${CONVERTED_CHECKPOINT_PATH}/0/items

# Note that the `CONVERTED_CHECKPOINT` is in a `scanned` format which is great for training but for efficient decoding performance we want the checkpoint in an `unscanned` format.
# We can do this by running `MaxText/generate_param_only_checkpoint.py` on `CONVERTED_CHECKPOINT` with `force_unroll=true`.
export DIRECT_PARAMETER_CHECKPOINT_RUN=direct_generate_param_only_checkpoint_${idx}
python3 MaxText/generate_param_only_checkpoint.py MaxText/configs/base.yml base_output_directory=${BASE_OUTPUT_DIRECTORY} load_parameters_path=${CONVERTED_CHECKPOINT} run_name=${DIRECT_PARAMETER_CHECKPOINT_RUN} model_name='llama2-7b' hardware=gpu async_checkpointing=${ASYNC_CHECKPOINTING}

export RUN_NAME="llama-2-1vm-$(date +%Y-%m-%d-%H-%M)"

# Set environment variables
for ARGUMENT in "$@"; do
    IFS='=' read -r KEY VALUE <<< "$ARGUMENT"
    export "$KEY"="$VALUE"
done

export XLA_PYTHON_CLIENT_MEM_FRACTION=0.85
export CUDA_DEVICE_MAX_CONNECTIONS=1
export NVTE_FUSED_ATTN=1
export NCCL_DEBUG=VERSION

export XLA_FLAGS="--xla_dump_to=$BASE_OUTPUT_PATH/$RUN_NAME/HLO_dumps/
--xla_gpu_enable_latency_hiding_scheduler=true --xla_gpu_enable_triton_gemm=false
 --xla_gpu_graph_level=0 --xla_gpu_enable_highest_priority_async_stream=true
 --xla_gpu_all_reduce_combine_threshold_bytes=134217728 --xla_gpu_all_gather_combine_threshold_bytes=134217728
 --xla_gpu_reduce_scatter_combine_threshold_bytes=67108864 --xla_gpu_enable_pipelined_all_gather=true
 --xla_gpu_enable_pipelined_reduce_scatter=true --xla_gpu_enable_pipelined_all_reduce=true
 --xla_gpu_enable_while_loop_double_buffering=true --xla_gpu_enable_triton_softmax_fusion=false
 --xla_gpu_enable_all_gather_combine_by_dim=false --xla_gpu_enable_reduce_scatter_combine_by_dim=false
 --xla_disable_hlo_passes=rematerialization"

python MaxText/train.py MaxText/configs/base.yml run_name=$RUN_NAME hardware=gpu steps=30 dcn_data_parallelism=1 ici_fsdp_parallelism=8 per_device_batch_size=4 max_target_length=4096 model_name=llama2-7b enable_checkpointing=true attention=cudnn_flash_te remat_policy=minimal_flash use_iota_embed=true scan_layers=false dataset_type=synthetic async_checkpointing=${ASYNC_CHECKPOINTING} base_output_directory=$BASE_OUTPUT_DIRECTORY enable_profiler=false

export XLA_PYTHON_CLIENT_MEM_FRACTION=0.65
export TF_FORCE_GPU_ALLOW_GROWTH=true

python3 MaxText/decode.py MaxText/configs/base.yml load_parameters_path=${BASE_OUTPUT_DIRECTORY}/${RUN_NAME}/checkpoints/0/items run_name=runner_decode_finetuned_${idx} base_output_directory=${BASE_OUTPUT_DIRECTORY} per_device_batch_size=1 model_name='llama2-7b' ici_autoregressive_parallelism=4 max_prefill_predict_length=4  max_target_length=16 prompt="I love to" attention=dot_product scan_layers=false hardware=gpu async_checkpointing=${ASYNC_CHECKPOINTING}
