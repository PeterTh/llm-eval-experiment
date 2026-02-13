require 'fileutils'
require 'open3'
require 'yaml'

PAR_OMP = "omp"
PAR_CUDA = "cuda"
PAR_MPI = "mpi"
PAR_HYBRID = "hybrid"

PARALLELIZATION_TYPES = [PAR_OMP, PAR_CUDA, PAR_MPI, PAR_HYBRID]
