module stiff_ode

  use amrex_constants_module
  use amrex_fort_module, only : rt => amrex_real
  use burn_type_module
  use bs_type_module
#ifdef SIMPLIFIED_SDC
  use bs_rhs_module
  use bs_jac_module
#else
  use rhs_module
  use jac_module
#endif

  implicit none

  real(rt), parameter, private :: dt_min = 1.e-24_rt
  real(rt), parameter, private :: dt_ini = 1.e-16_rt
  real(rt), parameter, private :: SMALL = 1.e-30_rt


  ! error codes
  integer, parameter :: IERR_NONE = 0
  integer, parameter :: IERR_DT_TOO_SMALL = -100
  integer, parameter :: IERR_TOO_MANY_STEPS = -101
  integer, parameter :: IERR_DT_UNDERFLOW = -102
  integer, parameter :: IERR_NO_CONVERGENCE = -103

  integer, parameter :: IERR_LU_DECOMPOSITION_ERROR = -200


  ! these are parameters for the BS method
  real(rt), parameter :: S1 = 0.25_rt
  real(rt), parameter :: S2 = 0.7_rt

  real(rt), parameter :: RED_BIG_FACTOR = 0.7_rt
  real(rt), parameter :: RED_SMALL_FACTOR = 1.e-5_rt
  real(rt), parameter :: SCALMX = 0.1_rt

  ! these are parameters for the Rosenbrock method
  real(rt), parameter :: GAMMA = HALF
  real(rt), parameter :: A21 = TWO
  real(rt), parameter :: A31 = 48.0_rt/25.0_rt
  real(rt), parameter :: A32 = SIX/25.0_rt
  ! note: we are using the fact here that for both the original Kaps
  ! and Rentrop params and the parameters from Shampine (that NR
  ! likes) we have A41 = A31, A42 = A32, and A43 = 0, so the last 2
  ! solves use the same intermediate y (see Stoer & Bulirsch, TAM,
  ! p. 492)
  real(rt), parameter :: C21 = -EIGHT
  real(rt), parameter :: C31 = 372.0_rt/25.0_rt
  real(rt), parameter :: C32 = TWELVE/FIVE
  real(rt), parameter :: C41 = -112.0_rt/125.0_rt
  real(rt), parameter :: C42 = -54.0_rt/125.0_rt
  real(rt), parameter :: C43 = -TWO/FIVE
  real(rt), parameter :: B1 = 19.0_rt/NINE
  real(rt), parameter :: B2 = HALF
  real(rt), parameter :: B3 = 25.0_rt/108.0_rt
  real(rt), parameter :: B4 = 125.0_rt/108.0_rt
  real(rt), parameter :: E1 = 17.0_rt/54.0_rt
  real(rt), parameter :: E2 = 7.0_rt/36.0_rt
  real(rt), parameter :: E3 = ZERO
  real(rt), parameter :: E4 = 125.0_rt/108.0_rt
  real(rt), parameter :: A2X = ONE
  real(rt), parameter :: A3X = THREE/FIVE

  real(rt), parameter :: SAFETY = 0.9_rt
  real(rt), parameter :: GROW = 1.5_rt
  real(rt), parameter :: PGROW = -0.25_rt
  real(rt), parameter :: SHRINK = HALF
  real(rt), parameter :: PSHRINK = -THIRD
  real(rt), parameter :: ERRCON = 0.1296_rt

  integer, parameter :: MAX_TRY = 50

contains

  ! integrate from t to tmax

  subroutine safety_check(y_old, y, retry)
    !$acc routine seq

    use extern_probin_module, only: safety_factor
    
    real(rt), intent(in) :: y_old(bs_neqs), y(bs_neqs)
    logical, intent(out) :: retry

    real(rt) :: ratio

    retry = .false.

    ratio = abs(y(net_itemp)/y_old(net_itemp))
    if (ratio > safety_factor) then ! .or. ratio < ONE/safety_factor) then
       retry = .true.
    endif

    ratio = abs(y(net_ienuc)/y_old(net_ienuc))
    if (ratio > safety_factor) then ! .or. ratio < ONE/safety_factor) then
       retry = .true.
    endif

    ! not sure what check to do on species
    
  end subroutine safety_check

  
  subroutine ode(bs, t, tmax, eps, ierr)

    ! this is a basic driver for the ODE integration, based on the NR
    ! routine.  This calls an integration method to take a single step
    ! and return an estimate of the net step size needed to achieve
    ! our desired tolerance.

    !$acc routine seq

    use extern_probin_module, only: ode_max_steps, use_timestep_estimator, &
                                    scaling_method, ode_scale_floor, ode_method
#ifndef ACC
    use amrex_error_module, only: amrex_error
#endif

    type (bs_t), intent(inout) :: bs

    real(rt), intent(inout) :: t
    real(rt), intent(in) :: tmax
    real(rt), intent(in) :: eps
    integer, intent(out) :: ierr

    real(rt) :: yscal(bs_neqs)
    logical :: finished

    integer :: n

    ! initialize

    bs % t = t
    bs % tmax = tmax

    finished = .false.
    ierr = IERR_NONE

    bs % eps_old = ZERO

    if (use_timestep_estimator) then
#ifdef SIMPLIFIED_SDC
       call f_bs_rhs(bs)
#else
       call f_rhs(bs)
#endif
       call initial_timestep(bs)
    else
       bs % dt = dt_ini
    endif

    do n = 1, ode_max_steps

       ! Get the scaling.
#ifdef SIMPLIFIED_SDC
       call f_bs_rhs(bs)
#else
       call f_rhs(bs)
#endif

       if (scaling_method == 1) then
          yscal(:) = abs(bs % y(:)) + abs(bs % dt * bs % ydot(:)) + SMALL

       else if (scaling_method == 2) then
          yscal = max(abs(bs % y(:)), ode_scale_floor)

#ifndef ACC
       else
          call amrex_error("Unknown scaling_method in ode")
#endif
       endif

       ! make sure we don't overshoot the ending time
       if (bs % t + bs % dt > tmax) bs % dt = tmax - bs % t

       ! take a step -- this routine will update the solution array,
       ! advance the time, and also give an estimate of the next step
       ! size
       if (ode_method == 1) then
          call single_step_bs(bs, eps, yscal, ierr)
       else if (ode_method == 2) then
          call single_step_rosen(bs, eps, yscal, ierr)
#ifndef ACC
       else
          call amrex_error("Unknown ode_method in ode")
#endif
       endif

       if (ierr /= IERR_NONE) then
          exit
       end if

       ! finished?
       if (bs % t - tmax >= ZERO) then
          finished = .true.
       endif

       bs % dt = bs % dt_next

       if (bs % dt < dt_min) then
          ierr = IERR_DT_TOO_SMALL
          exit
       endif

       if (finished) exit

    enddo

    bs % n = n

    if (.not. finished .and. ierr == IERR_NONE) then
       ierr = IERR_TOO_MANY_STEPS
    endif

  end subroutine ode



  subroutine initial_timestep(bs)

    ! this is a version of the timestep estimation algorithm used by
    ! VODE

    !$acc routine seq

    type (bs_t), intent(inout) :: bs

    type (bs_t) :: bs_temp
    real(rt) :: h, h_old, hL, hU, ddydtt(bs_neqs), eps, ewt(bs_neqs), yddnorm
    integer :: n

    bs_temp = bs

    eps = maxval(bs % rtol)

    ! Initial lower and upper bounds on the timestep

    hL = 100.0e0_rt * epsilon(ONE) * max(abs(bs % t), abs(bs % tmax))
    hU = 0.1e0_rt * abs(bs % tmax - bs % t)

    ! Initial guess for the iteration

    h = sqrt(hL * hU)
    h_old = 10.0_rt * h

    ! Iterate on ddydtt = (RHS(t + h, y + h * dydt) - dydt) / h

    do n = 1, 4

       h_old = h

       ! Get the error weighting -- this is similar to VODE's dewset
       ! routine

       ewt = eps * abs(bs % y) + SMALL

       ! Construct the trial point.

       bs_temp % t = bs % t + h
       bs_temp % y = bs % y + h * bs % ydot

       ! Call the RHS, then estimate the finite difference.
#ifdef SIMPLIFIED_SDC
       call f_bs_rhs(bs_temp)
#else
       call f_rhs(bs_temp)
#endif

       ddydtt = (bs_temp % ydot - bs % ydot) / h

       yddnorm = sqrt( sum( (ddydtt*ewt)**2 ) / bs_neqs )

       if (yddnorm*hU*hU > TWO) then
          h = sqrt(TWO / yddnorm)
       else
          h = sqrt(h * hU)
       endif

       if (h_old < TWO * h .and. h_old > HALF * h) exit

    enddo

    ! Save the final timestep, with a bias factor.

    bs % dt = h / TWO
    bs % dt = min(max(h, hL), hU)

  end subroutine initial_timestep


  subroutine semi_implicit_extrap(bs, y, dt_tot, N_sub, y_out, ierr)

    !$acc routine seq

#ifdef VODE
    use linpack_module, only: dgesl, dgefa
#else
    !$acc routine(dgesl) seq
    !$acc routine(dgefa) seq
#endif

    implicit none

    type (bs_t), intent(inout) :: bs
    real(rt), intent(in) :: y(bs_neqs)
    real(rt), intent(in) :: dt_tot
    integer, intent(in) :: N_sub
    real(rt), intent(out) :: y_out(bs_neqs)
    integer, intent(out) :: ierr

    real(rt) :: A(bs_neqs,bs_neqs)
    real(rt) :: del(bs_neqs)
    real(rt) :: h

    integer :: n

    integer :: ipiv(bs_neqs), ierr_linpack

    type (bs_t) :: bs_temp

    real(rt) :: t

    ierr = IERR_NONE

    ! substep size
    h = dt_tot/N_sub

    ! I - h J
    A(:,:) = -h * bs % jac(:,:)
    do n = 1, bs_neqs
       A(n,n) = ONE + A(n,n)
    enddo

    ! get the LU decomposition from LINPACK
#ifdef VODE
    call dgefa(A, ipiv, ierr_linpack)
#else
    call dgefa(A, bs_neqs, bs_neqs, ipiv, ierr_linpack)
#endif
    if (ierr_linpack /= 0) then
       ierr = IERR_LU_DECOMPOSITION_ERROR
    endif

    if (ierr == IERR_NONE) then
       bs_temp = bs
#ifdef SIMPLIFIED_SDC
       bs_temp % n_rhs = 0
#else
       bs_temp % burn_s % n_rhs = 0
#endif

       ! do an Euler step to get the RHS for the first substep
       t = bs % t
       y_out(:) = h * bs % ydot(:)

       ! solve the first step using the LU solver
#ifdef VODE
       call dgesl(A, ipiv, y_out)
#else
       call dgesl(A, bs_neqs, bs_neqs, ipiv, y_out, 0)
#endif

       del(:) = y_out(:)
       bs_temp % y(:) = y(:) + del(:)

       t = t + h
       bs_temp % t = t
#ifdef SIMPLIFIED_SDC
       call f_bs_rhs(bs_temp)
#else
       call f_rhs(bs_temp)
#endif

       do n = 2, N_sub
          y_out(:) = h * bs_temp % ydot(:) - del(:)

          ! LU solve
#ifdef VODE
          call dgesl(A, ipiv, y_out)
#else
          call dgesl(A, bs_neqs, bs_neqs, ipiv, y_out, 0)
#endif

          del(:) = del(:) + TWO * y_out(:)
          bs_temp % y = bs_temp % y + del(:)

          t = t + h
          bs_temp % t = t
#ifdef SIMPLIFIED_SDC
          call f_bs_rhs(bs_temp)
#else
          call f_rhs(bs_temp)
#endif
       enddo

       y_out(:) = h * bs_temp % ydot(:) - del(:)

       ! last LU solve
#ifdef VODE
       call dgesl(A, ipiv, y_out)
#else
       call dgesl(A, bs_neqs, bs_neqs, ipiv, y_out, 0)
#endif

       ! last step
       y_out(:) = bs_temp % y(:) + y_out(:)
    
       ! Store the number of function evaluations.

#ifdef SIMPLIFIED_SDC
       bs % n_rhs = bs % n_rhs + bs_temp % n_rhs
#else
       bs % burn_s % n_rhs = bs % burn_s % n_rhs + bs_temp % burn_s % n_rhs
#endif
    else
       y_out(:) = y(:)
    endif
       
  end subroutine semi_implicit_extrap



  subroutine single_step_bs(bs, eps, yscal, ierr)

    !$acc routine seq

#ifndef ACC
    use amrex_error_module, only: amrex_error
#endif

    implicit none

    type (bs_t) :: bs
    real(rt), intent(in) :: eps
    real(rt), intent(in) :: yscal(bs_neqs)
    integer, intent(out) :: ierr

    real(rt) :: y_save(bs_neqs), yerr(bs_neqs), yseq(bs_neqs)
    real(rt) :: err(KMAXX)

    real(rt) :: dt, fac, scale, red, eps1, work, work_min, xest
    real(rt) :: err_max

    logical :: converged, reduce, skip_loop, retry

    integer :: i, k, n, kk, km, kstop, ierr_temp
    integer, parameter :: max_iters = 10 ! Should not need more than this

    ! for internal storage of the polynomial extrapolation
    real(rt) :: t_extrap(KMAXX+1), qcol(bs_neqs, KMAXX+1)

    ! reinitialize
    if (eps /= bs % eps_old) then
       bs % dt_next = -1.e29_rt
       bs % t_new = -1.e29_rt
       eps1 = S1*eps

       bs % a(1) = nseq(1)+1
       do k = 1, KMAXX
          bs % a(k+1) = bs % a(k) + nseq(k+1)
       enddo

       ! compute alpha coefficients (NR 16.4.10)
       do i = 2, KMAXX
          do k = 1, i-1
             bs % alpha(k,i) = &
                  eps1**((bs % a(k+1) - bs % a(i+1)) / &
                         ((bs % a(i+1) - bs % a(1) + ONE)*(2*k+1)))
          enddo
       enddo

       bs % eps_old = eps

       bs % a(1) = bs_neqs + bs % a(1)
       do k = 1, KMAXX
          bs % a(k+1) = bs % a(k) + nseq(k+1)
       enddo

       ! optimal row number
       do k = 2, KMAXX-1
          if (bs % a(k+1) > bs % a(k)* bs % alpha(k-1,k)) exit
       enddo

       bs % kopt = k
       bs % kmax = k

    endif

    dt = bs % dt
    y_save(:) = bs % y(:)

    ! get the jacobian
#ifdef SIMPLIFIED_SDC
    call bs_jac(bs)
#else
    call jac(bs)
#endif

    if (dt /= bs % dt_next .or. bs % t /= bs % t_new) then
       bs % first = .true.
       bs % kopt = bs % kmax
    endif

    reduce = .false.

    converged = .false.

    km = -1
    kstop = -1

    do n = 1, max_iters

       ! setting skip_loop = .true. in the next loop is a GPU-safe-way to
       ! indicate that we are discarding this timestep attempt and will
       ! instead try again in the next `n` iteration
       skip_loop = .false.
       retry = .false.

       ! each iteration is a new attempt at taking a step, so reset
       ! errors at the start of the attempt
       ierr = IERR_NONE
       
       do k = 1, bs % kmax

          if (.not. skip_loop) then

             bs % t_new = bs % t + dt

             call semi_implicit_extrap(bs, y_save, dt, nseq(k), yseq, ierr_temp)
             ierr = ierr_temp
             if (ierr == IERR_LU_DECOMPOSITION_ERROR) then
                skip_loop = .true.
                red = ONE/nseq(k)
             endif

             call safety_check(y_save, yseq, retry)
             if (retry) then
                skip_loop = .true.
                red = RED_BIG_FACTOR
             endif

             if (ierr == IERR_NONE .and. .not. retry) then
                xest = (dt/nseq(k))**2
                call poly_extrap(k, xest, yseq, bs % y, yerr, t_extrap, qcol)

                if (k /= 1) then
                   err_max = max(SMALL, maxval(abs(yerr(:)/yscal(:))))
                   err_max = err_max / eps
                   km = k - 1
                   err(km) = (err_max/S1)**(1.0_rt/(2*km+1))
                endif

                if (k /= 1 .and. (k >=  bs % kopt-1 .or. bs % first)) then

                   if (err_max < 1) then
                      converged = .true.
                      kstop = k
                      exit
                   else

                      ! reduce stepsize if necessary
                      if (k == bs % kmax .or. k == bs % kopt+1) then
                         red = S2/err(km)
                         reduce = .true.
                         skip_loop = .true.
                      else if (k == bs % kopt) then
                         if (bs % alpha(bs % kopt-1, bs % kopt) < err(km)) then
                            red = ONE/err(km)
                            reduce = .true.
                            skip_loop = .true.
                         endif
                      else if (bs % kopt == bs % kmax) then
                         if (bs % alpha(km, bs % kmax-1) < err(km)) then
                            red = bs % alpha(km, bs % kmax-1)*S2/err(km)
                            reduce = .true.
                            skip_loop = .true.
                         endif
                      else if (bs % alpha(km, bs % kopt) < err(km)) then
                         red = bs % alpha(km, bs % kopt - 1)/err(km)
                         reduce = .true.
                         skip_loop = .true.
                      endif
                   endif

                endif

                kstop = k
             endif
          endif

       enddo

       if (.not. converged) then
          ! note, even if ierr /= IERR_NONE, we still try again, since
          ! we may eliminate LU decomposition errors (singular matrix)
          ! with a smaller timestep
          red = max(min(red, RED_BIG_FACTOR), RED_SMALL_FACTOR)
          dt = dt*red
       else
          exit
       endif

    enddo   ! iteration loop (n) varying dt

    if (.not. converged .and. ierr == IERR_NONE) then
       ierr = IERR_NO_CONVERGENCE
#ifndef ACC
       print *, "Integration failed due to non-convergence in single_step_bs"
       call dump_bs_state(bs)
       return
#endif       
    endif

#ifndef ACC
    ! km and kstop should have been set during the main loop.
    ! If they never got updated from the original nonsense values,
    ! that means something went really wrong and we should abort.

    if (km < 0) then
       call amrex_error("Error: km < 0 in subroutine single_step_bs, something has gone wrong.")
    endif

    if (kstop < 0) then
       call amrex_error("Error: kstop < 0 in subroutine single_step_bs, something has gone wrong.")
    endif
#endif

    bs % t = bs % t_new
    bs % dt_did = dt
    bs % first = .false.

    ! optimal convergence properties
    work_min = 1.e35_rt
    do kk = 1, km
       fac = max(err(kk), SCALMX)
       work = fac*bs % a(kk+1)

       if (work < work_min) then
          scale = fac
          work_min = work
          bs % kopt = kk+1
       endif
    enddo

    ! increase in order
    bs % dt_next = dt / scale

    if (bs % kopt >= kstop .and. bs % kopt /= bs % kmax .and. .not. reduce) then
       fac = max(scale/bs % alpha(bs % kopt-1, bs % kopt), SCALMX)
       if (bs % a(bs % kopt+1)*fac <= work_min) then
          bs % dt_next = dt/fac
          bs % kopt = bs % kopt + 1
       endif
    endif

  end subroutine single_step_bs


  subroutine poly_extrap(iest, test, yest, yz, dy, t, qcol)

    !$acc routine seq

    ! this does polynomial extrapolation according to the Neville
    ! algorithm.  Given test and yest (t and a y-array), this gives
    ! the value yz and the error in the extrapolation, dy by
    ! building a polynomial through the points, where the order
    ! is iest

    integer, intent(in) :: iest
    real(rt), intent(in) :: test, yest(bs_neqs)
    real(rt), intent(inout) :: yz(bs_neqs), dy(bs_neqs)

    ! these are for internal storage to save the state between calls
    real(rt), intent(inout) :: t(KMAXX+1), qcol(bs_neqs, KMAXX+1)

    integer :: j, k
    real(rt) :: delta, f1, f2, q, d(bs_neqs)

    t(iest) = test

    dy(:) = yest(:)
    yz(:) = yest(:)

    if (iest == 1) then
       ! nothing to do -- this is just a constant
       qcol(:,1) = yest(:)
    else
       ! we have more than 1 point, so build higher order
       ! polynomials
       d(:) = yest(:)

       do k = 1, iest-1
          delta = ONE/(t(iest-k)-test)
          f1 = test*delta
          f2 = t(iest-k)*delta

          do j = 1, bs_neqs
             q = qcol(j,k)
             qcol(j,k) = dy(j)
             delta = d(j) - q
             dy(j) = f1*delta
             d(j) = f2*delta
             yz(j) = yz(j) + dy(j)

          enddo

       enddo
       qcol(:,iest) = dy(:)
    endif

  end subroutine poly_extrap


  subroutine single_step_rosen(bs, eps, yscal, ierr)

    ! this does a single step of the Rosenbrock method.  Note: we
    ! assume here that our RHS is not an explicit function of t, but
    ! only of our integration variable, y

    !$acc routine seq

#ifdef VODE
    use linpack_module, only: dgesl, dgefa
#else
    !$acc routine(dgesl) seq
    !$acc routine(dgefa) seq
#endif
#ifndef ACC
    use amrex_error_module, only: amrex_error
#endif

    implicit none

    type (bs_t) :: bs
    real(rt), intent(in) :: eps
    real(rt), intent(in) :: yscal(bs_neqs)
    integer, intent(out) :: ierr
    
    real(rt) :: A(bs_neqs,bs_neqs)
    real(rt) :: g1(bs_neqs), g2(bs_neqs), g3(bs_neqs), g4(bs_neqs)
    real(rt) :: err(bs_neqs)

    real(rt) :: h, h_tmp, errmax

    integer :: q, n

    integer :: ipiv(bs_neqs), ierr_linpack

    type (bs_t) :: bs_temp

    logical :: converged

    h = bs % dt

    ! note: we come in already with a RHS evalulation from the driver

    ! get the jacobian
#ifdef SIMPLIFIED_SDC
    call bs_jac(bs)
#else
    call jac(bs)
#endif

    ierr = IERR_NONE

    converged = .false.

    q = 1
    do while (q <= MAX_TRY .and. .not. converged .and. ierr == IERR_NONE)

       bs_temp = bs

       ! create I/(gamma h) - ydot -- this is the matrix used for all the
       ! linear systems that comprise a single step
       A(:,:) = -bs % jac(:,:)
       do n = 1, bs_neqs
          A(n,n) = ONE/(gamma * h) + A(n,n)
       enddo
       
       ! LU decomposition
#ifdef VODE
       call dgefa(A, ipiv, ierr_linpack)
#else
       call dgefa(A, bs_neqs, bs_neqs, ipiv, ierr_linpack)
#endif
       if (ierr_linpack /= 0) then
          ierr = IERR_LU_DECOMPOSITION_ERROR
       endif
       
       ! setup the first RHS and solve the linear system (note: the linear
       ! solve replaces the RHS with the solution in place)
       g1(:) = bs % ydot(:)

#ifdef VODE
       call dgesl(A, ipiv, g1)
#else
       call dgesl(A, bs_neqs, bs_neqs, ipiv, g1, 0)
#endif

       ! new value of y
       bs_temp % y(:) = bs % y(:) + A21*g1(:)
       bs_temp % t = bs % t + A2X*h
       
       ! get derivatives at this intermediate position and setup the next
       ! RHS
#ifdef SIMPLIFIED_SDC
       call f_bs_rhs(bs_temp)
#else
       call f_rhs(bs_temp)
#endif

       g2(:) = bs_temp % ydot(:) + C21*g1(:)/h

#ifdef VODE
       call dgesl(A, ipiv, g2)
#else
       call dgesl(A, bs_neqs, bs_neqs, ipiv, g2, 0)
#endif

       ! new value of y
       bs_temp % y(:) = bs % y(:) + A31*g1(:) + A32*g2(:)
       bs_temp % t = bs % t + A3X*h

       ! get derivatives at this intermediate position and setup the next
       ! RHS
#ifdef SIMPLIFIED_SDC
       call f_bs_rhs(bs_temp)
#else
       call f_rhs(bs_temp)
#endif

       g3(:) = bs_temp % ydot(:) + (C31*g1(:) + C32*g2(:))/h

#ifdef VODE
       call dgesl(A, ipiv, g3)
#else
       call dgesl(A, bs_neqs, bs_neqs, ipiv, g3, 0)
#endif

       ! our choice of parameters prevents us from needing another RHS 
       ! evaluation here

       ! final intermediate RHS
       g4(:) = bs_temp % ydot(:) + (C41*g1(:) + C42*g2(:) + C43*g3(:))/h

#ifdef VODE
       call dgesl(A, ipiv, g4)
#else
       call dgesl(A, bs_neqs, bs_neqs, ipiv, g4, 0)
#endif

       ! now construct our 4th order estimate of y
       bs_temp % y(:) = bs % y(:) + B1*g1(:) + B2*g2(:) + B3*g3(:) + B4*g4(:)
       bs_temp % t = bs % t + h
       err(:) = E1*g1(:) + E2*g2(:) + E3*g3(:) + E4*g4(:)

       if (bs_temp % t == bs % t) then
          ierr = IERR_DT_UNDERFLOW
       endif

       ! get the error and scale it to the desired tolerance
       errmax = maxval(abs(err(:)/yscal(:)))
       errmax = errmax/eps

       if (errmax <= 1) then
          ! we were successful -- store the solution
          bs % y(:) = bs_temp % y(:)
          bs % t = bs_temp % t
#ifdef SIMPLIFIED_SDC
          bs % n_rhs = bs_temp % n_rhs
#else
          bs % burn_s % n_rhs = bs_temp % burn_s % n_rhs
#endif

          bs % dt_did = h
          if (errmax > ERRCON) then
             bs % dt_next = SAFETY*h*errmax**PGROW
          else
             bs % dt_next = GROW*h
          endif
          
          converged = .true.

       else if (ierr == IERR_NONE) then
          ! integration did not meet error criteria.  Return h and
          ! try again

          ! this is essentially the step control from Stoer &
          ! Bulircsh (TAM) Eq. 7.2.5.17, as shown on p. 493
          h_tmp = SAFETY*h*errmax**PSHRINK

          h = sign(max(abs(h_tmp), SHRINK*abs(h)), h)
       endif
          
       q = q + 1
       
    enddo
    
    if (.not. converged .and. ierr == IERR_NONE) then
       ierr = IERR_NO_CONVERGENCE
    endif

  end subroutine single_step_rosen

end module stiff_ode

