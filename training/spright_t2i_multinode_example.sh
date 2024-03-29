#! /bin/bash

#SBATCH -p PP
#SBATCH --gres=gpu:8
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=80
#SBATCH -N 4
#SBATCH --job-name=spatial_finetuning_stable_diffusion


conda activate env_name
cd /path/to/training/script

export MODEL_NAME="SPRIGHT-T2I/spright-t2i-sd2"
export OUTDIR="/path/to/output/dir"
export SPRIGHT_SPLIT="path/to/spright/metadata.json"

ACCELERATE_CONFIG_FILE="$OUTDIR/${SLURM_JOB_ID}_accelerate_config.yaml.autogenerated"


GPUS_PER_NODE=8
NNODES=$SLURM_NNODES
NUM_GPUS=$((GPUS_PER_NODE*SLURM_NNODES))

MASTER_ADDR=$(scontrol show hostnames $SLURM_JOB_NODELIST | head -n 1)
MASTER_PORT=25215

# Auto-generate the accelerate config
cat << EOT > $ACCELERATE_CONFIG_FILE
compute_environment: LOCAL_MACHINE
deepspeed_config: {}
distributed_type: MULTI_GPU
fsdp_config: {}
machine_rank: 0
main_process_ip: $MASTER_ADDR
main_process_port: $MASTER_PORT
main_training_function: main
num_machines: $SLURM_NNODES
num_processes: $NUM_GPUS
use_cpu: false
EOT

# accelerate settings
# Note: it is important to escape `$SLURM_PROCID` since we want the srun on each node to evaluate this variable
export LAUNCHER="accelerate launch \
    --rdzv_conf "rdzv_backend=c10d,rdzv_endpoint=$MASTER_ADDR:$MASTER_PORT,max_restarts=0,tee=3" \
    --config_file $ACCELERATE_CONFIG_FILE \
    --main_process_ip $MASTER_ADDR \
    --main_process_port $MASTER_PORT \
    --num_processes $NUM_GPUS \
    --machine_rank \$SLURM_PROCID \
    "

# train
PROGRAM="train.py \
  --pretrained_model_name_or_path=$MODEL_NAME \
  --use_ema \
  --seed 42 \
  --mixed_precision="fp16" \
  --resolution=768 --center_crop --random_flip \
  --train_batch_size=4 \
  --gradient_accumulation_steps=1 \
  --max_train_steps=15000 \
  --learning_rate=5e-06 \
  --max_grad_norm=1 \
  --lr_scheduler="constant" \
  --lr_warmup_steps=0 \
  --output_dir=$OUTDIR \
  --train_metadata_dir=$TRAIN_METADIR \
  --dataloader=$DATA_LOADER \
  --checkpointing_steps=1500 \
  --freeze_text_encoder_steps=0 \
  --train_text_encoder \
  --text_encoder_lr=1e-06 \
  --spright_splits $SPRIGHT_SPLIT
  "


# srun error handling:
# --wait=60: wait 60 sec after the first task terminates before terminating all remaining tasks
# --kill-on-bad-exit=1: terminate a step if any task exits with a non-zero exit code
SRUN_ARGS=" \
    --wait=60 \
    --kill-on-bad-exit=1 \
    "

export CMD="$LAUNCHER $PROGRAM"
echo $CMD

srun $SRUN_ARGS --jobid $SLURM_JOB_ID bash -c "$CMD"

