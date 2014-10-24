#include <iostream>
#include <fstream>
#include <map>
#include <string>
#include <vector>
#include <cstring>
#include <omp.h>
#include <cstdio>
#include "../buffer_pool.h"
#include "../common.h"
#include "../init.h"
#include "../cuda_includes.h"
#include "../matrix.h"
#include "../timer.h"
#include "../partition.h"

#include "cpu/pot.h"

using std::cout;
using std::endl;
using std::vector;

namespace G2G { 

template<class scalar_type> void PointGroup<scalar_type>::solve(Timers& timers,
  bool compute_rmm, bool lda, bool compute_forces, bool compute_energy, 
  double& energy, double& energy_i, double& energy_c, double& energy_c1, double& energy_c2,
  HostMatrix<double> & fort_forces, int inner_threads, HostMatrix<scalar_type> & rmm_global_output, bool OPEN)
{

  solve_closed(timers, compute_rmm, lda, compute_forces, compute_energy, 
    energy, fort_forces, inner_threads, rmm_global_output);
}

template<class scalar_type> void PointGroup<scalar_type>::solve_closed(Timers& timers,
  bool compute_rmm, bool lda, bool compute_forces, bool compute_energy, 
  double& energy, HostMatrix<double> & fort_forces, int inner_threads, HostMatrix<scalar_type> & rmm_global_output)
{
  const uint group_m = total_functions();

  #if CPU_RECOMPUTE
  /** Compute functions **/
  timers.functions.start();
  compute_functions(compute_forces, !lda);
  timers.functions.pause();
  #endif

  double localenergy = 0.0;

  // prepare rmm_input for this group
  timers.density.start();

  timers.rmm_input.start();
  HostMatrix<scalar_type> rmm_input(group_m, group_m);
  get_rmm_input(rmm_input);
  timers.rmm_input.pause();

  timers.density.pause();

  vector<vec_type3> forces;
  vector< std::vector<vec_type3> > forces_mat;
  HostMatrix<scalar_type> factors_rmm; 
  vector<scalar_type>factors_y2a;
      
  if(compute_rmm) factors_rmm.resize(points.size(), 1);

  if(compute_forces) {
    factors_y2a.resize(points.size());
    forces.resize(total_nucleii(), vec_type3(0.f,0.f,0.f)); 
    forces_mat.resize(points.size(), vector<vec_type3>(total_nucleii(), vec_type3(0.f,0.f,0.f)));
  }

  timers.density.start();

  const int iexch = fortran_vars.iexch;

  /** density **/
  if (lda) {
    for(int point = 0; point < points.size(); point++) {
      scalar_type partial_density = 0;
      for (uint i = 0; i < group_m; i++) {
        scalar_type w = 0.0;
        scalar_type Fi = function_values(i, point);
        for (uint j = i; j < group_m; j++) {
          scalar_type Fj = function_values(j, point);
          w += rmm_input(j, i) * Fj;
        }
        partial_density += Fi * w;
      }
      scalar_type exc = 0, corr = 0, y2a = 0;
      cpu_pot(partial_density, exc, corr, y2a, iexch);

      localenergy +=  (partial_density * points[point].weight) * (exc + corr);

      /** forces **/
      if (compute_forces) {
        factors_y2a[point] = y2a;
      }

      /** RMM **/
      if (compute_rmm) {
        factors_rmm(point) = points[point].weight * y2a;
      }
    }
  } else {
    timers.density_calcs.start();

    #pragma omp parallel for num_threads(inner_threads) reduction(+:localenergy)
    for(int point = 0; point < points.size(); point++) {
      scalar_type pd, tdx, tdy, tdz, tdd1x, tdd1y, tdd1z,tdd2x, tdd2y, tdd2z;
      pd = tdx = tdy = tdz = tdd1x = tdd1y = tdd1z = tdd2x = tdd2y = tdd2z = 0;

      const scalar_type * fv = function_values.row(point);
      const scalar_type * gxv = gX.row(point);
      const scalar_type * gyv = gY.row(point);
      const scalar_type * gzv = gZ.row(point);
      const scalar_type * hpxv = hPX.row(point);
      const scalar_type * hpyv = hPY.row(point);
      const scalar_type * hpzv = hPZ.row(point);
      const scalar_type * hixv = hIX.row(point);
      const scalar_type * hiyv = hIY.row(point);
      const scalar_type * hizv = hIZ.row(point);

      for (int i = 0; i < group_m; i++) {
        scalar_type w = 0;
        scalar_type w3xc = 0, w3yc = 0, w3zc = 0;
        scalar_type ww1xc = 0, ww1yc = 0, ww1zc = 0;
        scalar_type ww2xc = 0, ww2yc = 0, ww2zc = 0;

        const scalar_type * rm = rmm_input.row(i);
        const scalar_type Fi = fv[i];
        const scalar_type gx = gxv[i], gy = gyv[i], gz = gzv[i];
        const scalar_type hpx = hpxv[i], hpy = hpyv[i], hpz = hpzv[i];
        const scalar_type hix = hixv[i], hiy = hiyv[i], hiz = hizv[i];

        #pragma vector aligned always nontemporal
        for(int j = 0; j <= i; j++) {
          w += fv[j] * rm[j];
          w3xc += gxv[j] * rm[j];
          w3yc += gyv[j] * rm[j];
          w3zc += gzv[j] * rm[j];
          ww1xc += hpxv[j] * rm[j];
          ww1yc += hpyv[j] * rm[j];
          ww1zc += hpzv[j] * rm[j];
          ww2xc += hixv[j] * rm[j];
          ww2yc += hiyv[j] * rm[j];
          ww2zc += hizv[j] * rm[j];
        }

        pd += Fi * w;

        tdx += gx * w + w3xc * Fi;
        tdd1x += gx * w3xc * 2 + hpx * w + ww1xc * Fi;
        tdd2x += gx * w3yc + gy * w3xc + hix * w + ww2xc * Fi;

        tdy += gy * w + w3yc * Fi;
        tdd1y += gy * w3yc * 2 + hpy * w + ww1yc * Fi;
        tdd2y += gx * w3zc + gz * w3xc + hiy * w + ww2yc * Fi;

        tdz += gz * w + w3zc * Fi;
        tdd1z += gz * w3zc * 2 + hpz * w + ww1zc * Fi;
        tdd2z += gy * w3zc + gz * w3yc + hiz * w + ww2zc * Fi;
      }

      /** energy / potential **/
      scalar_type exc = 0, corr = 0, y2a = 0;
      vec_type3 dxyz(tdx,tdy,tdz);
      vec_type3 dd1(tdd1x,tdd1y,tdd1z);
      vec_type3 dd2(tdd2x,tdd2y,tdd2z);

      cpu_potg(pd, dxyz, dd1, dd2, exc, corr, y2a, iexch);

      if (compute_energy) {
        localenergy +=  (pd * points[point].weight) * (exc + corr);
      }

      /** forces **/
      if (compute_forces) {
        factors_y2a[point] = y2a;
      }

      /** RMM **/
      if (compute_rmm) {
        factors_rmm(point) = points[point].weight * y2a;
      }
    }
    timers.density_calcs.pause();
  }

  timers.forces.start();
  if (compute_forces) {
    HostMatrix<scalar_type> ddx,ddy,ddz;
    ddx.resize(total_nucleii(), 1); 
    ddy.resize(total_nucleii(), 1); 
    ddz.resize(total_nucleii(), 1); 
    #pragma omp parallel for num_threads(inner_threads)
    for(int point = 0; point < points.size(); point++) {
      ddx.zero(); ddy.zero(); ddz.zero();
      for (uint i = 0, ii = 0; i < total_functions_simple(); i++) {
        uint nuc = func2local_nuc(ii);
        uint inc_i = small_function_type(i);
        scalar_type tddx = 0, tddy = 0, tddz = 0;
        for (uint k = 0; k < inc_i; k++, ii++) {
          scalar_type w = 0.0;
          for (uint j = 0; j < group_m; j++) {
            scalar_type Fj = function_values(j, point);
            w += rmm_input(j, ii) * Fj * (ii == j ? 2 : 1);
          }
          tddx -= w*gX(ii, point); tddy -= w*gY(ii, point); tddz -= w*gZ(ii, point);
        }
        ddx(nuc) += tddx; ddy(nuc) += tddy; ddz(nuc) += tddz;
      }
      scalar_type factor = points[point].weight * factors_y2a[point];
      for (uint i = 0; i < total_nucleii(); i++) {
        forces_mat[point][i] = vec_type3(ddx(i),ddy(i),ddz(i)) * factor;
      }
    }
    /* accumulate forces for each point */
    if(forces_mat.size() > 0) {
      for (int j = 0; j < forces_mat[0].size(); j++) {
        vec_type3 acum(0.f,0.f,0.f);
        for (int i = 0; i < forces_mat.size(); i++) {
          acum += forces_mat[i][j];
        }
        forces[j] = acum;
      }
    }
    /* accumulate force results for this group */
    for (uint i = 0; i < total_nucleii(); i++) {
      uint global_atom = local2global_nuc[i];
      vec_type3 this_force = forces[i];
      fort_forces(global_atom,0) += this_force.x();
      fort_forces(global_atom,1) += this_force.y();
      fort_forces(global_atom,2) += this_force.z();
    }
  }
  timers.forces.pause();

  timers.rmm.start();
  /* accumulate RMM results for this group */
  if(compute_rmm) {
    const int indexes = rmm_bigs.size();
    const int npoints = points.size();
    #pragma omp parallel for num_threads(inner_threads)
    for(int i = 0; i < indexes; i++) {
      int bi = rmm_bigs[i], row = rmm_rows[i], col = rmm_cols[i];
      scalar_type res = 0;
      const scalar_type * fvr = function_values_transposed.row(row);
      const scalar_type * fvc = function_values_transposed.row(col);
    
      #pragma vector aligned always nontemporal
      for(int point = 0; point < npoints; point++) {
        res += fvr[point] * fvc[point] * factors_rmm(point);
      }
      rmm_global_output(bi) += res;
    }
  }

  timers.rmm.pause();
  energy+=localenergy;

#if CPU_RECOMPUTE
  /* clear functions */
  function_values.deallocate();
  gradient_values.deallocate();
  hessian_values.deallocate();
#endif
}

template class PointGroup<double>;
template class PointGroup<float>;

}
