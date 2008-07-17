/* -*- mode: c -*- */
#include <cstdio>
#include "double.h"
#include "cuda_extra.h"
#include "../matrix.h"
#include "accum.h"
#include "exchnum.h"
#include "exchnum_constants.h"
#include "../timer.h"

#include <cassert>

using namespace G2G;
using namespace std;

/** KERNELS **/
#include "functions.h"
#include "density.h"
#include "pot.h"
#include "energy.h"
#include "rmm.h"
#include "force.h"

/**
 * Fortran interface
 */

/** TODO: ----- ARREGLAR ESTO ---------- */
#define FORTRAN_MAX_ATOMS 1860
#define FORTRAN_NG 3000
#define FORTRAN_NL 10

uint using_grid_type = 9999;

/** Kernel variables / Matrices **/
//CudaMatrixFloat3 gpu_atom_positions;
CudaMatrixFloat2 gpu_factor_ac;
CudaMatrixUInt gpu_nuc, gpu_contractions;
CudaMatrixFloat gpu_rmm;
HostMatrixUInt types;
//CudaMatrixUInt gpu_types;
uint nco;

bool cuda_init = false;

/**
 * Parametros innecesarios: m (es sum(num_funcs))
 */
extern "C" void exchnum_gpu_(const unsigned int& norm, const unsigned int& natom, const double* r, const unsigned int* Iz, const unsigned int* Nuc,
														 const unsigned int& m, const unsigned int* ncont, const unsigned int* nshell, const double* c, const double* a,
														 double* RMM, const unsigned int& m18, const unsigned int& m5, const unsigned int& fort_nco, double& Exc, const unsigned int& nopt,
														 const unsigned int& Iexch, const unsigned int& igrid,
														 const double* e, const double* e2, const double* e3,
														 const double* fort_wang, const double* fort_wang2, const double* fort_wang3,
														 const unsigned int& Ndens, double* fort_forces, const unsigned int& computation_type)
{
	bool compute_energy = false; bool update_rmm = false; bool compute_forces = false;
	printf("<======= GPU ========>\n");
	switch(computation_type) {
		case 0: compute_energy = true; update_rmm = false; compute_forces = false; break;
		case 1: compute_energy = false; update_rmm = true; compute_forces = false; break;
		case 2: compute_energy = true; update_rmm = false; compute_forces = true; break;		
	}

#ifdef _DEBUG	
	if (!cuda_init) {
		cuInit(0);
		cuda_init = true;
	}
#endif	
	
	#ifdef _DEBUG
	compute_energy = true;
	#endif	
	
	printf("calcular energias: %s | actualizar rmm: %s | calcular fuerzas: %s\n",
				 compute_energy ? "si" : "no", update_rmm ? "si" : "no", compute_forces ? "si" : "no");
	
	_DBG(printf("Ndens: %i\n", Ndens));
	
	uint3 num_funcs = make_uint3(nshell[0], nshell[1], nshell[2]);
	uint3 num_funcs_div = num_funcs / make_uint3(1, 3, 6);
	
	uint total_funcs = sum(num_funcs);
	uint total_funcs_div = sum(num_funcs_div);
	
	assert(natom <= MAX_ATOMS);
	
	/* output_rmm size: TODO: divUp(m * (m - 1),2) */
	
	// REVISAR: nuc: imagen y dominio (especialmente por la parte de * 3 y * 6)

	_DBG(printf("%i atoms\n", natom));
	//if (!gpu_atom_positions_matrix.is_allocated())
	{
		HostMatrixFloat3 cpu_atom_positions(natom, 1);
		for (unsigned int i = 0; i < natom; i++) {
			cpu_atom_positions.data[i] = make_float3(r[FORTRAN_MAX_ATOMS * 0 + i], r[i + FORTRAN_MAX_ATOMS * 1], r[i + FORTRAN_MAX_ATOMS * 2]);
		}
		cudaMemcpyToSymbol("gpu_atom_positions", cpu_atom_positions.data, natom * sizeof(float3), 0, cudaMemcpyHostToDevice);
	}

	if (!types.is_allocated()) {
		types.resize(natom, 1);
		for (unsigned int i = 0; i < natom; i++) {
			types.data[i] = Iz[i] - 1;
		}
		cudaMemcpyToSymbol("gpu_types", types.data, natom * sizeof(uint), 0, cudaMemcpyHostToDevice);		
		cudaMemcpyToSymbol("Iexch_gpu", &Iexch, sizeof(uint), 0, cudaMemcpyHostToDevice);
	}
	
	_DBG(printf("ns: %i, np: %i, nd: %i, Total_Funcs: %i\n", num_funcs.x, num_funcs.y, num_funcs.z, total_funcs));
	if (!gpu_factor_ac.is_allocated())	
	{
		HostMatrixFloat2 factor_ac_matrix(total_funcs, MAX_CONTRACTIONS);
		HostMatrixUInt nuc_matrix(total_funcs_div, 1), contractions_matrix(total_funcs_div, 1);
		
		uint inc = 1;
		uint i, j;
		for (i = 0, j = 0; i < total_funcs; i += inc, j++) {
			if (i == num_funcs.x) inc = 3;
			else if (i == (num_funcs.x + num_funcs.y)) inc = 6;

			//printf("i: %i, j: %i\n", i, j);
			//printf("Nuc(%i) = %i\n", i, Nuc[i] - 1);
			//printf("ncont(%i) = %i\n", i, ncont[i]);
			nuc_matrix.data[j] = Nuc[i] - 1;
			contractions_matrix.data[j] = ncont[i];
			
			for (unsigned int k = 0; k < ncont[i]; k++) {
				factor_ac_matrix.data[j * MAX_CONTRACTIONS + k] = make_float2(a[FORTRAN_NG * k + i], c[FORTRAN_NG * k + i]);
				//printf("cont: %i, a: %f, c: %f\n", k, factor_a.data[j * MAX_CONTRACTIONS + k], factor_c.data[j * MAX_CONTRACTIONS + k]);
			}			
		}
		gpu_factor_ac = factor_ac_matrix;
		gpu_nuc = nuc_matrix;
		gpu_contractions = contractions_matrix;
	}
	
	nco = fort_nco;
	_DBG(printf("NCO: %i, M: %i, Iexch: %i\n", nco, total_funcs, Iexch));
	assert(Iexch <= 3);
	{
		HostMatrixFloat rmm;
		
		if (Ndens == 1) {
			//rmm.resize(m * m);
			rmm.resize(m * (m + 1) / 2);
			uint k = 0;
			for (unsigned int i = 0; i < m; i++) {
				for (unsigned int j = i; j < m; j++) {
					rmm.data[k] = RMM[k];
					//printf("rmm(%i): %.30e\n", k, RMM[m5 + k - 1]);
					k++;
				}
			}
		}
		else {
			rmm.resize(m, nco);
			uint k = m18 - 1;
			for (unsigned int i = 0; i < nco; i++) {
				for (unsigned int j = 0; j < m; j++) {
					rmm.data[i * m + j] = RMM[k];
					//printf("rmm(%i,%i): %.30e (%i)\n", i, j, RMM[k], k);
					k++;
				}
			}
		}
		gpu_rmm = rmm;
	}

	
	uint points = EXCHNUM_SMALL_GRID_SIZE;
	switch (igrid) {
		case 0: points = EXCHNUM_SMALL_GRID_SIZE; 	break;
		case 1: points = EXCHNUM_MEDIUM_GRID_SIZE;	break;
		case 2: points = EXCHNUM_BIG_GRID_SIZE;			break;
	}	
	
	/** load grid if it changes **/
	if (using_grid_type != igrid) {
		_DBG(printf("Nueva Grilla: %i:\n", igrid));
		
		using_grid_type = igrid;	
		
		const double* real_e = NULL;
		const double* real_wang = NULL;
		switch (igrid) {
			case 0: real_e = e;  real_wang = fort_wang;  	break;
			case 1: real_e = e2; real_wang = fort_wang2; 	break;
			case 2: real_e = e3; real_wang = fort_wang3; 	break;
		}
		
		HostMatrixFloat wang(points, 1);
		HostMatrixFloat3 point_positions(points, 1);

		for (unsigned int i = 0; i < points; i++) {
			wang.data[i] = real_wang[i];
			point_positions.data[i] = make_float3(real_e[0 * points + i], real_e[1 * points + i], real_e[2 * points + i]);
			//printf("wang: %f, e: (%f,%f,%f)\n", wang.data[i], point_positions.data[i].x, point_positions.data[i].y, point_positions.data[i].z);
		}

		switch (igrid) {
			case 0:
				cudaMemcpyToSymbol("gpu_point_positions", point_positions.data, EXCHNUM_SMALL_GRID_SIZE * sizeof(float3), 0, cudaMemcpyHostToDevice);
				cudaMemcpyToSymbol("gpu_wang", wang.data, EXCHNUM_SMALL_GRID_SIZE * sizeof(float), 0, cudaMemcpyHostToDevice);
			break;
			case 1:
				cudaMemcpyToSymbol("gpu_point_positions", point_positions.data, EXCHNUM_MEDIUM_GRID_SIZE * sizeof(float3), 0, cudaMemcpyHostToDevice);
				cudaMemcpyToSymbol("gpu_wang", wang.data, EXCHNUM_MEDIUM_GRID_SIZE * sizeof(float), 0, cudaMemcpyHostToDevice);
			break;
			case 2:
				cudaMemcpyToSymbol("gpu_point_positions", point_positions.data, EXCHNUM_BIG_GRID_SIZE * sizeof(float3), 0, cudaMemcpyHostToDevice);
				cudaMemcpyToSymbol("gpu_wang", wang.data, EXCHNUM_BIG_GRID_SIZE * sizeof(float), 0, cudaMemcpyHostToDevice);
			break;
		}
	}
			
	calc_energy(igrid, points, Ndens, num_funcs_div, norm, Exc, &RMM[m5-1], fort_forces, compute_energy, update_rmm, compute_forces);
}

/**
 * Host <-> CUDA Communication function
 */
void calc_energy(uint grid_type, uint npoints, uint Ndens, uint3 num_funcs, bool normalize, double& energy, double* cpu_rmm_output, double* cpu_forces_output,
								 bool compute_energy, bool update_rmm, bool compute_forces)
{
	uint m = num_funcs.x + num_funcs.y * 3 + num_funcs.z * 6;	
	uint small_m = sum(num_funcs);
	
	uint natoms = types.width;
		
	/* outputs */
	CudaMatrixFloat gpu_energy, gpu_functions(m *  (natoms * MAX_LAYERS * npoints));
	_DBG(printf("gpu_functions: %i (%i bytes) data: %i\n", gpu_functions.elements(), gpu_functions.bytes(), (bool)gpu_functions.data));
	
	CudaMatrixFloat gpu_rmm_output;
	if (update_rmm) {
		gpu_rmm_output.resize((m * (m + 1)) / 2);
		_DBG(printf("gpu_rmm_output: %i (%i bytes) data: %i\n", gpu_rmm_output.elements(), gpu_rmm_output.bytes(), (bool)gpu_rmm_output.data));
	}
		
	if (compute_energy) {
		gpu_energy.resize(natoms * MAX_LAYERS * npoints);
		_DBG(printf("gpu_energy: %i (%i bytes) data: %i\n", gpu_energy.elements(), gpu_energy.bytes(), (bool)gpu_energy.data));
	}
	
	CudaMatrixFloat gpu_factor_output;
	if (update_rmm || compute_forces) {
		gpu_factor_output.resize(natoms * MAX_LAYERS * npoints);
		_DBG(printf("gpu_factor_output: %i (%i bytes) data: %i\n", gpu_factor_output.elements(), gpu_factor_output.bytes(), (bool)gpu_factor_output.data));
	}
	
	CudaMatrixFloat3 gpu_forces, gpu_dd, gpu_Fg, gpu_w3;
	if (compute_forces) {
		gpu_forces.resize(natoms);
		_DBG(printf("gpu_forces: %i (%i bytes) data: %i\n", gpu_forces.elements(), gpu_forces.bytes(), (bool)gpu_forces.data));
		gpu_dd.resize(natoms * (natoms * MAX_LAYERS * npoints));
		_DBG(printf("gpu_dd: %i (%i bytes) data: %i\n", gpu_dd.elements(), gpu_dd.bytes(), (bool)gpu_dd.data));
		gpu_Fg.resize(m * (natoms * npoints));
		_DBG(printf("gpu_Fg: %i (%i bytes) data: %i\n", gpu_Fg.elements(), gpu_Fg.bytes(), (bool)gpu_Fg.data));
		gpu_w3.resize(natoms * (natoms * npoints));
		_DBG(printf("gpu_w3: %i (%i bytes) data: %i\n", gpu_w3.elements(), gpu_w3.bytes(), (bool)gpu_w3.data));
	}
	
	// TODO: update_rmm should be a template parameter
	const uint* curr_cpu_layers = NULL;	

	/* thread / block / grid */
	dim3 energy_threads(natoms, npoints);
	dim3 energy_blockSize;
	switch (grid_type) {
		case 0:	energy_blockSize = (compute_forces ? dim3(ENERGY_FORCE_BLOCK_SIZE_X, ENERGY_FORCE_BLOCK_SIZE_Y) : dim3(ENERGY_S_BLOCK_SIZE_X, ENERGY_S_BLOCK_SIZE_Y)); break;
		case 1:	energy_blockSize = (compute_forces ? dim3(ENERGY_FORCE_BLOCK_SIZE_X, ENERGY_FORCE_BLOCK_SIZE_Y) : dim3(ENERGY_M_BLOCK_SIZE_X, ENERGY_M_BLOCK_SIZE_Y)); break;
		case 2:	energy_blockSize = (compute_forces ? dim3(ENERGY_FORCE_BLOCK_SIZE_X, ENERGY_FORCE_BLOCK_SIZE_Y) : dim3(ENERGY_B_BLOCK_SIZE_X, ENERGY_B_BLOCK_SIZE_Y)); break;
	}
	dim3 energy_gridSize = divUp(energy_threads, energy_blockSize);
	_DBG(printf("energy threads: %i %i, blockSize: %i %i, gridSize: %i %i\n", energy_threads.x, energy_threads.y,
				 energy_blockSize.x, energy_blockSize.y, energy_gridSize.x, energy_gridSize.y));
	
	dim3 rmm_threads(m, m);
	dim3 rmm_blockSize(RMM_BLOCK_SIZE_X, RMM_BLOCK_SIZE_Y);
	dim3 rmm_gridSize = divUp(rmm_threads, rmm_blockSize);	
	_DBG(printf("rmm threads: %i %i, blockSize: %i %i, gridSize: %i %i\n", rmm_threads.x, rmm_threads.y, rmm_blockSize.x, rmm_blockSize.y, rmm_gridSize.x, rmm_gridSize.y));
	
	dim3 force_threads(natoms);
	dim3 force_blockSize(natoms < FORCE_BLOCK_SIZE ? natoms : FORCE_BLOCK_SIZE);
	dim3 force_gridSize = divUp(force_threads, force_blockSize);
	_DBG(printf("force threads: %i %i, blockSize: %i %i, gridSize: %i %i\n", force_threads.x, force_threads.y, force_blockSize.x, force_blockSize.y, force_gridSize.x, force_gridSize.y));
	
//#ifdef _DEBUG	
	uint free_memory, total_memory;
	cuMemGetInfo(&free_memory, &total_memory);
	_DBG(printf("Memoria libre: %i de %i => Memoria usada: %i\n", free_memory, total_memory, total_memory - free_memory));
//#endif
	
	switch(grid_type) {
		case 0:
		{
			_DBG(printf("energy_kernel\n"));

			if (compute_forces) {
				energy_kernel<true, EXCHNUM_SMALL_GRID_SIZE, GPU_LAYERS_2>
					<<< energy_gridSize, energy_blockSize >>>(gpu_energy.data,
																										types.width, nco, num_funcs, gpu_nuc.data, gpu_contractions.data,
																										normalize, gpu_factor_ac.data, gpu_rmm.data, gpu_functions.data,
																										Ndens, gpu_factor_output.data, gpu_dd.data, gpu_Fg.data, gpu_w3.data, compute_energy, update_rmm);
			}
			else {
				energy_kernel<false, EXCHNUM_SMALL_GRID_SIZE, GPU_LAYERS_2>
					<<< energy_gridSize, energy_blockSize >>>(gpu_energy.data,
																										types.width, nco, num_funcs, gpu_nuc.data, gpu_contractions.data,
																										normalize, gpu_factor_ac.data, gpu_rmm.data, gpu_functions.data,
																										Ndens, gpu_factor_output.data, gpu_dd.data, gpu_Fg.data, gpu_w3.data, compute_energy, update_rmm);
			}
			cudaAssertNoError("energy kernel");
			
			if (update_rmm) {
				_DBG(printf("calc_new_rmm\n"));
				calc_new_rmm<EXCHNUM_SMALL_GRID_SIZE, GPU_LAYERS_2>
					<<<rmm_gridSize, rmm_blockSize>>>(types.width, nco, num_funcs, gpu_nuc.data, gpu_contractions.data,
																						normalize, gpu_factor_ac.data, gpu_rmm.data, gpu_rmm_output.data,
																						gpu_factor_output.data, gpu_functions.data);
				cudaAssertNoError("rmm kernel");
			}
			
			if (compute_forces) {
				_DBG(printf("calc_forces\n"));
				calc_forces<EXCHNUM_SMALL_GRID_SIZE, GPU_LAYERS_2>
					<<<force_gridSize, force_blockSize>>>(types.width,
																								num_funcs, gpu_nuc.data, gpu_contractions.data,
																								normalize, gpu_factor_ac.data, gpu_factor_output.data, gpu_dd.data,
																								gpu_forces.data);
				cudaAssertNoError("forces kernel");
			}

			curr_cpu_layers = cpu_layers2;
		}
		break;
		case 1:
		{
			_DBG(printf("energy_kernel\n"));
			if (compute_forces) {
			energy_kernel<true, EXCHNUM_MEDIUM_GRID_SIZE, GPU_LAYERS_1>
				<<< energy_gridSize, energy_blockSize >>>(gpu_energy.data,
																									types.width, nco, num_funcs, gpu_nuc.data, gpu_contractions.data,
																									normalize, gpu_factor_ac.data, gpu_rmm.data, gpu_functions.data,
																									Ndens, gpu_factor_output.data, gpu_dd.data, gpu_Fg.data, gpu_w3.data, compute_energy, update_rmm);
			}
			else {
				energy_kernel<false, EXCHNUM_MEDIUM_GRID_SIZE, GPU_LAYERS_1>
				<<< energy_gridSize, energy_blockSize >>>(gpu_energy.data,
																									types.width, nco, num_funcs, gpu_nuc.data, gpu_contractions.data,
																									normalize, gpu_factor_ac.data, gpu_rmm.data, gpu_functions.data,
																									Ndens, gpu_factor_output.data, gpu_dd.data, gpu_Fg.data, gpu_w3.data, compute_energy, update_rmm);
			}
			cudaAssertNoError("energy kernel");
			
			if (update_rmm) {
				_DBG(printf("calc_new_rmm\n"));
				calc_new_rmm<EXCHNUM_MEDIUM_GRID_SIZE, GPU_LAYERS_1>
					<<<rmm_gridSize, rmm_blockSize>>>(types.width, nco, num_funcs, gpu_nuc.data, gpu_contractions.data,
																						normalize, gpu_factor_ac.data, gpu_rmm.data, gpu_rmm_output.data,
																						gpu_factor_output.data, gpu_functions.data);
				cudaAssertNoError("rmm kernel");				
			}

			if (compute_forces) {
				_DBG(printf("calc_forces\n"));
				calc_forces<EXCHNUM_MEDIUM_GRID_SIZE, GPU_LAYERS_1>
					<<<force_gridSize, force_blockSize>>>(types.width,
																								num_funcs, gpu_nuc.data, gpu_contractions.data,
																								normalize, gpu_factor_ac.data, gpu_factor_output.data, gpu_dd.data,
																								gpu_forces.data);
				cudaAssertNoError("forces kernel");
			}
			
			curr_cpu_layers = cpu_layers;
		}
		break;
		case 2:
		{
			_DBG(printf("energy_kernel\n"));
			if (compute_forces) {
				energy_kernel<true, EXCHNUM_BIG_GRID_SIZE, GPU_LAYERS_1>
					<<< energy_gridSize, energy_blockSize >>>(gpu_energy.data,
																										types.width, nco, num_funcs, gpu_nuc.data, gpu_contractions.data,
																										normalize, gpu_factor_ac.data, gpu_rmm.data, gpu_functions.data,
																										Ndens, gpu_factor_output.data, gpu_dd.data, gpu_Fg.data, gpu_w3.data, compute_energy, update_rmm);
			}
			else {
				energy_kernel<false, EXCHNUM_BIG_GRID_SIZE, GPU_LAYERS_1>
					<<< energy_gridSize, energy_blockSize >>>(gpu_energy.data,
																										types.width, nco, num_funcs, gpu_nuc.data, gpu_contractions.data,
																										normalize, gpu_factor_ac.data, gpu_rmm.data, gpu_functions.data,
																										Ndens, gpu_factor_output.data, gpu_dd.data, gpu_Fg.data, gpu_w3.data, compute_energy, update_rmm);
			}
			cudaAssertNoError("energy kernel");			

			if (update_rmm) {
				_DBG(printf("calc_new_rmm\n"));
				
				calc_new_rmm<EXCHNUM_BIG_GRID_SIZE, GPU_LAYERS_1>
					<<<rmm_gridSize, rmm_blockSize>>>(types.width, nco, num_funcs, gpu_nuc.data, gpu_contractions.data,
																						normalize, gpu_factor_ac.data, gpu_rmm.data, gpu_rmm_output.data,
																						gpu_factor_output.data, gpu_functions.data);
				cudaAssertNoError("rmm kernel");				
			}
			
			if (compute_forces) {
				_DBG(printf("calc_forces\n"));
				calc_forces<EXCHNUM_BIG_GRID_SIZE, GPU_LAYERS_1>
					<<<force_gridSize, force_blockSize>>>(types.width,
																								num_funcs, gpu_nuc.data, gpu_contractions.data,
																								normalize, gpu_factor_ac.data, gpu_factor_output.data, gpu_dd.data,
																								gpu_forces.data);
				cudaAssertNoError("forces kernel");
			}			
			
			curr_cpu_layers = cpu_layers;			
		}
		break;
	}
		
	/** Energy Accumulation */
	if (compute_energy)
	{		
		_DBG(printf("copia energias\n"));
		energy = 0.0;
		HostMatrixFloat cpu_energy(true);
		cpu_energy = gpu_energy;
		
		_DBG(printf("acumulacion energias\n"));
		for (uint i = 0; i < natoms; i++) {
			for (uint j = 0; j < curr_cpu_layers[types.data[i]]; j++) {
				for (uint k = 0; k < npoints; k++) {
					uint idx = index_from3d(dim3(energy_threads.x, MAX_LAYERS, energy_threads.y), dim3(i, j, k));
					//printf("idx: %i size: %i\n", idx, energy.elements());

					//printf("atomo: %i, capa: %i, punto: %i, valor: %.12e idx: %i\n", i, j, k, cpu_energy.data[idx], idx);
					energy += cpu_energy.data[idx];
				}
			}
		}
		_DBG(printf("energia gpu: %.15e\n", energy));
	}

	/** RMM update **/
	if (update_rmm) {
		
		_DBG(printf("copia rmm\n"));
		HostMatrixFloat gpu_rmm_output_copy(true);
		gpu_rmm_output_copy = gpu_rmm_output;

		_DBG(printf("acumulacion rmm\n"));
		uint rmm_idx = 0;
		for (uint func_i = 0; func_i < m; func_i++) {
			for (uint func_j = func_i; func_j < m; func_j++) {
				//printf("rmm_output(%i): %.12e\n", rmm_idx, gpu_rmm_output_copy.data[rmm_idx]);
				cpu_rmm_output[rmm_idx] += gpu_rmm_output_copy.data[rmm_idx];
				rmm_idx++;
			}
		}
	}
	
	/** Force update **/
	if (compute_forces) {
		_DBG(printf("copia fuerzas\n"));
		HostMatrixFloat3 cpu_forces;
		cpu_forces = gpu_forces;
		
		_DBG(printf("acumulacion fuerzas\n"));
		for (uint i = 0; i < natoms; i++) {
			cpu_forces_output[0 * FORTRAN_MAX_ATOMS + i] += cpu_forces.data[i].x;
			cpu_forces_output[1 * FORTRAN_MAX_ATOMS + i] += cpu_forces.data[i].y;
			cpu_forces_output[2 * FORTRAN_MAX_ATOMS + i] += cpu_forces.data[i].z;
		}
	}
	
	/*** DEBUG ***/
/*	if (compute_forces)
	{
		HostMatrixFloat3 cpu_dd(gpu_dd);
		for (uint i = 0; i < natoms; i++) {
			for (uint j = 0; j < curr_cpu_layers[types.data[i]]; j++) {
				for (uint k = 0; k < npoints; k++) {
					uint idx = index_from3d(dim3(energy_threads.x, MAX_LAYERS, energy_threads.y), dim3(i, j, k));

					for (uint atom_i = 0; atom_i < natoms; atom_i++)
						printf("dd %i %.12e %.12e %.12e %i %i %i %i\n", atom_i, cpu_dd.data[idx * natoms + atom_i].x, cpu_dd.data[idx * natoms + atom_i].y,
									 cpu_dd.data[idx * natoms + atom_i].z, idx, i, j, k);

				}
			}
		}

		HostMatrixFloat3 cpu_Fg(gpu_Fg);		
		for (uint i = 0; i < natoms; i++) {
			for (uint k = 0; k < npoints; k++) {

				uint idx = index_from3d(dim3(natoms, npoints, m), dim3(i, k, 0));

				for (uint l = 0; l < m; l++)
					printf("Fg %i %.12e %.12e %.12e %i\n", l, cpu_Fg.data[idx + l].x, cpu_Fg.data[idx + l].y, cpu_Fg.data[idx + l].z, idx);
			}
		}
	}*/
	

	
	printf("<======= FIN GPU ========>\n");	
	cudaAssertNoError("final");
}
