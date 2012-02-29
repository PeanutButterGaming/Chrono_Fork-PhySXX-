#include "ChLcpSolverGPU.h"

using namespace chrono;

//helper functions
template<class T, class U> // dot product of the first three elements of float3/float4 values
inline __host__ __device__ float dot3(const T & a, const U & b) {
	return a.x * b.x + a.y * b.y + a.z * b.z;
}

__constant__ float lcp_omega_bilateral_const;
__constant__ float lcp_omega_contact_const;
__constant__ float lcp_contact_factor_const;
__constant__ unsigned int number_of_objects_const;
__constant__ unsigned int number_of_contacts_const;
__constant__ unsigned int number_of_bilaterals_const;
__constant__ unsigned int number_of_updates_const;
//__constant__ float force_factor_const; // usually, the step size
//__constant__ float negated_recovery_speed_const;
__constant__ float step_size_const;
__constant__ float compliance_const;
__constant__ float complianceT_const;
__constant__ float alpha_const; // [R]=alpha*[K]
////////////////////////////////////////////////////////////////////////////////////////////////////
// Creates a quaternion as a function of a vector of rotation and an angle (the vector is assumed already
// normalized, and angle is in radians).

__host__ __device__ inline float4 Quat_from_AngAxis(const float &angle, const float3 & v) {
	float sinhalf = sinf(angle * 0.5f);
	float4 quat;
	quat.x = cosf(angle * 0.5f);
	quat.y = v.x * sinhalf;
	quat.z = v.y * sinhalf;
	quat.w = v.z * sinhalf;
	return quat;
}

/// The quaternion becomes the quaternion product of the two quaternions A and B:
/// following the classic Hamilton rule:  this=AxB
/// This is the true, typical quaternion product. It is NOT commutative.

__host__ __device__ inline float4 Quaternion_Product(const float4 &qa, const float4 &qb) {
	float4 quat;
	quat.x = qa.x * qb.x - qa.y * qb.y - qa.z * qb.z - qa.w * qb.w;
	quat.y = qa.x * qb.y + qa.y * qb.x - qa.w * qb.z + qa.z * qb.w;
	quat.z = qa.x * qb.z + qa.z * qb.x + qa.w * qb.y - qa.y * qb.w;
	quat.w = qa.x * qb.w + qa.w * qb.x - qa.z * qb.y + qa.y * qb.z;
	return quat;
}

__host__ __device__ void inline Compute_Jacobian(
        float3 &A,
        float3 &B,
        float3 &C,
        float4 TT,
        const float3 &n,
        const float3 &u,
        const float3 &w,
        const float3 &pos) {
	float t00 = pos.z * n.y - pos.y * n.z;
	float t01 = TT.x * TT.x;
	float t02 = TT.y * TT.y;
	float t03 = TT.z * TT.z;
	float t04 = TT.w * TT.w;
	float t05 = t01 + t02 - t03 - t04;
	float t06 = -pos.z * n.x + pos.x * n.z;
	float t07 = TT.y * TT.z;
	float t08 = TT.x * TT.w;
	float t09 = t07 + t08;
	float t10 = pos.y * n.x - pos.x * n.y;
	float t11 = TT.y * TT.w;
	float t12 = TT.x * TT.z;
	float t13 = t11 - t12;
	float t14 = t07 - t08;
	float t15 = t01 - t02 + t03 - t04;
	float t16 = TT.z * TT.w;
	float t17 = TT.x * TT.y;
	float t18 = t16 + t17;
	float t19 = t11 + t12;
	float t20 = t16 - t17;
	float t21 = t01 - t02 - t03 + t04;
	float t22 = pos.z * u.y - pos.y * u.z;
	float t23 = -pos.z * u.x + pos.x * u.z;
	float t24 = pos.y * u.x - pos.x * u.y;
	float t25 = pos.z * w.y - pos.y * w.z;
	float t26 = -pos.z * w.x + pos.x * w.z;
	float t27 = pos.y * w.x - pos.x * w.y;
	A.x = t00 * t05 + 2 * t06 * t09 + 2 * t10 * t13;
	A.y = 2 * t00 * t14 + t06 * t15 + 2 * t10 * t18;
	A.z = 2 * t00 * t19 + 2 * t06 * t20 + t10 * t21;
	B.x = t22 * t05 + 2 * t23 * t09 + 2 * t24 * t13;
	B.y = 2 * t22 * t14 + t23 * t15 + 2 * t24 * t18;
	B.z = 2 * t22 * t19 + 2 * t23 * t20 + t24 * t21;
	C.x = t25 * t05 + 2 * t26 * t09 + 2 * t27 * t13;
	C.y = 2 * t25 * t14 + t26 * t15 + 2 * t27 * t18;
	C.z = 2 * t25 * t19 + 2 * t26 * t20 + t27 * t21;
}
__host__ __device__ void inline Compute_Jacobian_2(
        float3 &T3,
        float3 &T4,
        float3 &T5,
        float4 Eb,
        const float3 &N,
        const float3 &U,
        const float3 &W,
        const float3 &pb) {

	float t1 = Eb.y * Eb.z;
	float t2 = Eb.x * Eb.w;
	float t3 = 2 * t1 - 2 * t2;
	float t4 = Eb.y * Eb.w;
	float t5 = Eb.x * Eb.z;
	float t6 = 2 * t4 + 2 * t5;
	float t7 = Eb.z * Eb.w;
	float t8 = Eb.x * Eb.y;
	float t9 = 2 * t7 - 2 * t8;
	float t10 = pow(Eb.x, 2);
	float t11 = pow(Eb.y, 2);
	float t12 = pow(Eb.w, 2);
	float t13 = pow(Eb.z, 2);
	float t14 = t10 - t11 - t13 + t12;
	float t15 = t6 * pb.x + t9 * pb.y + t14 * pb.z;
	float t16 = t10 - t11 + t13 - t12;
	t7 = 2 * t7 + 2 * t8;
	t8 = -t3 * pb.x - t16 * pb.y - t7 * pb.z;
	float t17 = t3 * t15 + t6 * t8;
	float t18 = t16 * t15 + t9 * t8;
	float t19 = t7 * t15 + t14 * t8;
	t10 = t10 + t11 - t13 - t12;
	t11 = -t15;
	t1 = 2 * t1 + 2 * t2;
	t2 = 2 * t4 - 2 * t5;
	t4 = t10 * pb.x + t1 * pb.y + t2 * pb.z;
	t5 = t10 * t11 + t6 * t4;
	t6 = t1 * t11 + t9 * t4;
	t9 = t2 * t11 + t14 * t4;
	t8 = -t8;
	t4 = -t4;
	t3 = t10 * t8 + t3 * t4;
	t1 = t1 * t8 + t16 * t4;
	t2 = t2 * t8 + t7 * t4;
	T3.x = N.x * t17 + N.y * t18 + N.z * t19;
	T3.y = N.x * t5 + N.y * t6 + N.z * t9;
	T3.z = N.x * t3 + N.y * t1 + N.z * t2;
	T4.x = U.x * t17 + U.y * t18 + U.z * t19;
	T4.y = U.x * t5 + U.y * t6 + U.z * t9;
	T4.z = U.x * t3 + U.y * t1 + U.z * t2;
	T5.x = W.x * t17 + W.y * t18 + W.z * t19;
	T5.y = W.x * t5 + W.y * t6 + W.z * t9;
	T5.z = W.x * t3 + W.y * t1 + W.z * t2;
}



// 	Kernel for a single iteration of the LCP over all contacts
//   	Version 2.0 - Tasora
//	Version 2.2- Hammad (optimized, cleaned etc)
__global__ void LCP_Iteration_Contacts(
        float3* norm,
        float3* ptA,
        float3* ptB,
        float* contactDepth,
        int2* ids,
        float3* G,
        float* dG,
        float3* aux,
        float3* inertia,
        float4* rot,
        float3* vel,
        float3* omega,
        float3* pos,
        float3* updateV,
        float3* updateO,
        uint* offset) {
	unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
	if (i >= number_of_contacts_const) {
		return;
	}
	//if(dG[i]<1e-8){dG[i]=0;return;}
	float4 E1, E2;
	float3 vB, gamma, N, U, W, T3, T4, T5, T6, T7, T8, gamma_old, sbar, V1, V2, In1, In2, W1, W2, aux1, aux2;
	float mu, eta, depth, bi, f_tang, tproj_div_t;
	//long long id=ids[i];
	int2 temp_id = ids[i];
	depth = -fabs(contactDepth[i]);
	//printf("%f ", depth);
	int B1_i = temp_id.x;
	int B2_i = temp_id.y;
	V1 = vel[B1_i];
	V2 = vel[B2_i];
	aux1 = aux[B1_i];
	aux2 = aux[B2_i];
	N = norm[i]; //assume: normalized, and if depth=0 norm=(1,0,0)



	W = fabs(N); //Gramm Schmidt; work with the global axis that is "most perpendicular" to the contact normal vector;effectively this means looking for the smallest component (in abs) and using the corresponding direction to carry out cross product.
	U = F3(0.0, N.z, -N.y); //it turns out that X axis is closest to being perpendicular to contact vector;
	if (W.x > W.y) {
		U = F3(-N.z, 0.0, N.x);
	} //it turns out that Y axis is closest to being perpendicular to contact vector;
	if (W.y > W.z) {
		U = F3(N.y, -N.x, 0.0);
	} //it turns out that Z axis is closest to being perpendicular to contact vector;
	U = normalize(U); //normalize the local contact Y,Z axis
	W = cross(N, U); //carry out the last cross product to find out the contact local Z axis : multiply the contact normal by the local Y component

	//printf("N: [%f %f %f]  [%f %f %f] [%f %f %f]%f \n", N.x, N.y, N.z,U.x, U.y, U.z,W.x, W.y, W.z, depth);


	sbar = ptA[i] - pos[B1_i]; //Contact Point on A - Position of A
	E1 = rot[B1_i]; //bring in the Euler parameters associated with body 1;
	Compute_Jacobian_2(T3, T4, T5, E1, N, U, W, sbar); //A_i,p'*A_A*(sbar~_i,A)


	sbar = ptB[i] - pos[B2_i]; //Contact Point on B - Position of B
	E2 = rot[B2_i]; //bring in the Euler parameters associated with body 2;
	Compute_Jacobian_2(T6, T7, T8, E2, N, U, W, sbar); //A_i,p'*A_B*(sbar~_i,B)

	//printf("Pa: [%f %f %f]\n", ptA[i].x, ptA[i].y, ptA[i].z);
	//printf("Pb: [%f %f %f]\n", ptB[i].x, ptB[i].y, ptB[i].z);

	//printf("A: [%f, %f, %f]",T3.x,T3.y,T3.z);
	//printf(" [%f, %f, %f]",T4.x,T4.y,T4.z);
	//printf(" [%f, %f, %f] \n",T5.x,T5.y,T5.z);

	T6 = -T6;
	T7 = -T7;
	T8 = -T8;

	//printf("B: [%f, %f, %f]",T6.x,T6.y,T6.z);
	//printf(" [%f, %f, %f]",T7.x,T7.y,T7.z);
	//printf(" [%f, %f, %f] \n",T8.x,T8.y,T8.z);

	W1 = omega[B1_i];
	W2 = omega[B2_i];

	mu = (aux1.y + aux2.y) * .5;

	float normV = dot(N, ((V2 - V1)));
	normV = (normV > 0) ? 0 : normV;
	float cfm = 0, cfmT = 0;
	if (compliance_const) {
		float h = step_size_const;
		float inv_hpa = 1.0 / (h + alpha_const); // 1/(h+a)
		float inv_hhpa = 1.0 / (h * (h + alpha_const)); // 1/(h*(h+a))
		bi = inv_hpa * depth;
		cfm = inv_hhpa * compliance_const;
		cfmT = inv_hhpa * complianceT_const;
	} else {
		bi = max((depth / (step_size_const)),-lcp_contact_factor_const);
	}
	//if (bi < -.1) {
	//	bi = -.1;
	//}

	//c_i = [Cq_i]*q + b_i + cfm_i*l_i
	gamma_old = G[i];
	gamma.x = dot(T3, W1) - dot(N, V1) + dot(T6, W2) + dot(N, V2) + bi + cfm * gamma_old.x; //+bi
	gamma.y = dot(T4, W1) - dot(U, V1) + dot(T7, W2) + dot(U, V2) + cfmT * gamma_old.y;
	gamma.z = dot(T5, W1) - dot(W, V1) + dot(T8, W2) + dot(W, V2) + cfmT * gamma_old.z;
	In1 = inertia[B1_i]; // bring in the inertia attributes; to be used to compute \eta
	In2 = inertia[B2_i]; // bring in the inertia attributes; to be used to compute \eta
	eta = dot(T3 * T3, In1) + dot(T4 * T4, In1) + dot(T5 * T5, In1); // update expression of eta
	eta += dot(T6 * T6, In2) + dot(T7 * T7, In2) + dot(T8 * T8, In2);
	eta += (dot(N, N) + dot(U, U) + dot(W, W)) * (aux1.z + aux2.z); // multiply by inverse of mass matrix of B1 and B2, add contribution from mass and matrix A_c.
	eta = lcp_omega_contact_const / eta; // final value of eta

	gamma = eta*gamma; // perform gamma *= omega*eta
	//if (isnan(gamma.x) || isnan(gamma.y) || isnan(gamma.z)) {printf("%f {%f, %f, %f} \n",bi, gamma.x, gamma.y, gamma.z); return;}

	gamma = gamma_old - gamma; // perform gamma = gamma_old - gamma ;  in place.
	/// ---- perform projection of 'a8' onto friction cone  --------
	f_tang = sqrtf(gamma.y * gamma.y + gamma.z * gamma.z);
	if (mu == 0) {
		gamma.y = gamma.z = 0;
	} else if (f_tang > (mu * gamma.x)) { // inside upper cone? keep untouched!
		if ((f_tang) < -(1.0 / mu) * gamma.x || (fabs(gamma.x) < 10e-15)) { // inside lower cone? reset  normal,u,v to zero!
			gamma = F3(0.f, 0.f, 0.f);
		} else { // remaining case: project orthogonally to generator segment of upper cone
			gamma.x = (f_tang * mu + gamma.x) / (mu * mu + 1.f);
			tproj_div_t = (gamma.x * mu) / f_tang; //  reg = tproj_div_t
			gamma.y *= tproj_div_t;
			gamma.z *= tproj_div_t;
		}
	}

	G[i] = gamma; // store gamma_new
	gamma -= gamma_old; // compute delta_gamma = gamma_new - gamma_old   = delta_gamma.
	//printf("[%f, %f, %f] \n",gamma.x, gamma.y,gamma.z );
	dG[i] = length(gamma);
	vB = N * gamma.x + U * gamma.y + W * gamma.z;
	int offset1 = offset[i];
	int offset2 = offset[i + number_of_contacts_const];
	if (aux1.x == 1) {
		updateV[offset1] = -vB * aux1.z; // compute and store dv1
		updateO[offset1] = (T3 * gamma.x + T4 * gamma.y + T5 * gamma.z) * In1; // compute dw1 =  Inert.1' * J1w^ * deltagamma  and store  dw1
	}
	if (aux2.x == 1) {
		updateV[offset2] = vB * aux2.z; // compute and store dv2
		updateO[offset2] = (T6 * gamma.x + T7 * gamma.y + T8 * gamma.z) * In2; // compute dw2 =  Inert.2' * J2w^ * deltagamma  and store  dw2
	}

	/*







	 */

}
///////////////////////////////////////////////////////////////////////////////////
// Kernel for a single iteration of the LCP over all scalar bilateral contacts
// (a bit similar to the ChKernelLCPiteration above, but without projection etc.)
// Version 2.0 - Tasora
//
__global__ void LCP_Iteration_Bilaterals(
        CH_REALNUMBER4* bilaterals,
        float3* aux,
        float3* inertia,
        float4* rot,
        float3* vel,
        float3* omega,
        float3* pos,
        float3* updateV,
        float3* updateO,
        uint* offset,
        float * dG) {
	unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
	if (i >= number_of_bilaterals_const) {
		return;
	}
	float4 vA;
	float3 vB;
	float gamma_new = 0, gamma_old = 0;
	int B1_index = 0, B2_index = 0;
	B1_index = bilaterals[i].w;
	B2_index = bilaterals[i + number_of_bilaterals_const].w;
	float3 aux1 = aux[B1_index];
	float3 aux2 = aux[B2_index];
	// ---- perform   gamma_new = ([J1 J2] {v1 | v2}^ + b)
	vA = bilaterals[i]; // line 0
	vB = vel[B1_index]; // v1
	gamma_new += dot3(vA, vB);

	vA = bilaterals[i + 2 * number_of_bilaterals_const];// line 2
	vB = omega[B1_index]; // w1
	gamma_new += dot3(vA, vB);

	vA = bilaterals[i + number_of_bilaterals_const]; // line 1
	vB = vel[B2_index]; // v2
	gamma_new += dot3(vA, vB);

	vA = bilaterals[i + 3 * number_of_bilaterals_const];// line 3
	vB = omega[B2_index]; // w2
	gamma_new += dot3(vA, vB);

	vA = bilaterals[i + 4 * number_of_bilaterals_const]; // line 4   (eta, b, gamma, 0)
	gamma_new += vA.y; // add known term     + b
	gamma_old = vA.z; // old gamma
	/// ---- perform gamma_new *= omega/g_i
	gamma_new *= lcp_omega_bilateral_const; // lcp_omega_const is in constant memory
	gamma_new *= vA.x; // eta = 1/g_i;
	/// ---- perform gamma_new = gamma_old - gamma_new ; in place.
	gamma_new = gamma_old - gamma_new;
	/// ---- perform projection of 'a' (only if simple unilateral behavior C>0 is requested)
	if (vA.w && gamma_new < 0.) {
		gamma_new = 0.;
	}
	// ----- store gamma_new
	vA.z = gamma_new;
	bilaterals[i + 4 * number_of_bilaterals_const] = vA;
	/// ---- compute delta in multipliers: gamma_new = gamma_new - gamma_old   = delta_gamma    , in place.
	gamma_new -= gamma_old;
	//dG[number_of_contacts_const + i] = (gamma_new);
	/// ---- compute dv1 =  invInert.18 * J1^ * deltagamma
	vB = inertia[B1_index]; // iJ iJ iJ im
	vA = (bilaterals[i]) * aux1.z * gamma_new; // line 0: J1(x)
	int offset1 = offset[2 * number_of_contacts_const + i];
	int offset2 = offset[2 * number_of_contacts_const + i + number_of_bilaterals_const];
	updateV[offset1] = F3(vA);//  ---> store  v1 vel. in reduction buffer
	updateO[offset1] = F3(bilaterals[i + 2 * number_of_bilaterals_const]) * vB * gamma_new;// line 2:  J1(w)// ---> store  w1 vel. in reduction buffer
	vB = inertia[B2_index]; // iJ iJ iJ im
	vA = (bilaterals[i + number_of_bilaterals_const]) * aux2.z * gamma_new; // line 1: J2(x)
	updateV[offset2] = F3(vA);//  ---> store  v2 vel. in reduction buffer
	updateO[offset2] = F3(bilaterals[i + 3 * number_of_bilaterals_const]) * vB * gamma_new;// line 3:  J2(w)// ---> store  w2 vel. in reduction buffer
}

__device__ __host__ inline float4 computeRot_dt(float3 & omega, float4 &rot) {
	return mult(F4(0, omega.x, omega.y, omega.z), rot) * .5;
}
__device__ __host__ float3 RelPoint_AbsSpeed(float3 & vel, float3 & omega, float4 & rot, float3 &point) {
	float4 q = mult(computeRot_dt(omega, rot), mult(F4(0, point.x, point.y, point.z), inv(rot)));
	return vel + ((F3(q.y, q.z, q.w)) * 2);
}

__global__ void DEM_Contacts(
        float3* norm,
        float3* ptA,
        float3* ptB,
        float* contactDepth,
        int2* ids,
        float3* aux,
        float3* inertia,
        float4* rot,
        float3* vel,
        float3* omega,
        float3* pos,
        float3* updateV,
        float3* updateO,
        uint* offset) {
	unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
	if (i >= number_of_contacts_const) {
		return;
	}
	float mkn = 3924, mgn = 420, mgt = 420, mkt = 2.0f / 7.0f * 3924;
	//long long id=ids[i];
	int2 temp_id = ids[i];
	int B1_i = int(temp_id.x);
	int B2_i = int(temp_id.y);

	float3 vN = norm[i]; //normal
	float3 pA = ptA[i];
	float3 pB = ptB[i];
	float3 B1 = vel[B1_i]; //vel B1
	float3 B2 = vel[B2_i]; //vel B2
	float3 oA = omega[B1_i];
	float3 oB = omega[B2_i];
	float4 rotA = rot[B1_i];
	float4 rotB = rot[B2_i];
	float3 aux1 = aux[B1_i];
	float3 aux2 = aux[B2_i];
	float3 posA = pos[B1_i];
	float3 posB = pos[B2_i];
	float3 f_n = mkn * -fabs(contactDepth[i]) * vN;
	float3 local_pA = quatRotate(pA - posA, inv(rotA));
	float3 local_pB = quatRotate(pB - posB, inv(rotB));

	float3 v_BA = (RelPoint_AbsSpeed(B2, oB, rotB, local_pB)) - (RelPoint_AbsSpeed(B1, oA, rotA, local_pA));
	float3 v_n = normalize(dot(v_BA, vN) * vN);
	float m_eff = (1.0 / aux1.z) * (1.0 / aux2.z) / (1.0 / aux1.z + 1.0 / aux2.z);
	f_n += mgn * m_eff * v_n;

	float mu = (aux1.y + aux2.y) * .5;
	float3 v_t = v_BA - v_n;

	float3 f_t = (mgt * m_eff * v_t) + (mkt * (v_t * step_size_const));

	if (length(f_t) > mu * length(f_n)) {
		f_t *= mu * length(f_n) / length(f_t);
	}

	float3 f_r = f_n + f_t;

	int offset1 = offset[i];
	int offset2 = offset[i + number_of_contacts_const];

	float3 force1_loc = quatRotate(f_r, inv(rotA));
	float3 force2_loc = quatRotate(f_r, inv(rotB));

	float3 trq1 = cross(local_pA, force1_loc);
	float3 trq2 = cross(local_pB, -force2_loc);

	f_r *= step_size_const;

	updateV[offset1] = (f_r) * aux1.z;
	updateV[offset2] = (f_r) * -aux2.z;

	updateO[offset1] = (trq1 * step_size_const) * (inertia[B1_i]);
	updateO[offset2] = (trq2 * step_size_const) * (inertia[B2_i]);
}

////////////////////////////////////////////////////////////////////////////////////////////////
// Kernel for adding invmass*force*step_size_const to body speed vector.
// This kernel must be applied to the stream of the body buffer.

__global__ void ChKernelLCPaddForces(float3* aux, float3* inertia, float3* forces, float3* torques, float3* vel, float3* omega) {
	// Compute the i values used to access data inside the large
	// array using pointer arithmetic.
	unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
	if (i < number_of_objects_const) {
		float3 temp_aux = aux[i];
		if (temp_aux.x != 0) {
			float3 mF, minvMasses = inertia[i];
			// v += m_inv * h * f
			mF = forces[i]; // vector with f (force)
			//mF *= 1;//step_size_const;
			mF *= temp_aux.z;
			vel[i] += mF;
			// w += J_inv * h * c
			mF = torques[i]; // vector with f (torque)
			//mF *= 1;//step_size_const;
			mF.x *= minvMasses.x;
			mF.y *= minvMasses.y;
			mF.z *= minvMasses.z;
			omega[i] += mF;
		}
	}
}
////////////////////////////////////////////////////////////////////////////////////////////////////
// Updates the speeds in the body buffer with values accumulated in the
// reduction buffer:   V_new = V_old + delta_speeds

__global__ void LCP_Reduce_Speeds(
        float3* aux,
        float3* vel,
        float3* omega,
        float3* updateV,
        float3* updateO,
        uint* d_body_num,
        uint* counter,
        float3* fap) {
	unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
	if (i >= number_of_updates_const) {
		return;
	}
	int start = (i == 0) ? 0 : counter[i - 1], end = counter[i];
	int id = d_body_num[end - 1], j;
	float3 auxd = aux[id];
	if (auxd.x == 1) {
		float3 mUpdateV = F3(0);
		float3 mUpdateO = F3(0);
		for (j = 0; j < end - start; j++) {
			mUpdateV += updateV[j + start];
			mUpdateO += updateO[j + start];
		}
		fap[id] += (mUpdateV / auxd.z) / step_size_const;
		vel[id] += mUpdateV;
		omega[id] += mUpdateO;
	}
}
//  Kernel for performing the time step integration (with 1st o;rder Eulero)
//  on the body data stream.
//
//  number of registers: 12 (suggested 320 threads/block)

__global__ void LCP_Integrate_Timestep(float3* aux, float3* acc, float4* rot, float3* vel, float3* omega, float3* pos, float3* lim) {
	unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
	if (i >= number_of_objects_const) {
		return;
	}
	float3 velocity = vel[i];
	float3 aux1 = aux[i];
	if (aux1.x == 0) {
		return;
	}

	// Do 1st order integration of quaternion position as q[t+dt] = qw_abs^(dt) * q[dt] = q[dt] * qw_local^(dt)
	// where qw^(dt) is the quaternion { cos(0.5|w|), wx/|w| sin(0.5|w|), wy/|w| sin(0.5|w|), wz/|w| sin(0.5|w|)}^dt
	// that is argument of sine and cosines are multiplied by dt.
	float3 omg = omega[i];

	float3 limits = lim[i];
	float wlen = length(omg);

		if (limits.x == 1) {
			float w = 2.0 * wlen;
			if (w > limits.z) {
				omg *= limits.z / w;
				wlen = sqrtf(dot3(omg, omg));
			}

			float v = length(velocity);
			if (v > limits.y) {
				velocity *= limits.y / v;
			}
			vel[i] = velocity;
			omega[i] = omg;
		}
	pos[i] = pos[i] + velocity * step_size_const; // Do 1st order integration of linear speeds

	float4 Rw = (fabs(wlen) > 10e-10) ? Quat_from_AngAxis(step_size_const * wlen, omg / wlen) : F4(1., 0, 0, 0);// to avoid singularity for near zero angular speed

	float4 mq = mult(rot[i], Rw);
	mq *= rsqrtf(dot(mq, mq));
	rot[i] = mq;
	acc[i] = (velocity - acc[i]) / step_size_const;
}
__global__ void LCP_ComputeGyro(float3* omega, float3* inertia, float3* gyro, float3* torque) {
	unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
	if (i >= number_of_objects_const) {
		return;
	}
	float3 body_inertia = inertia[i];
	body_inertia = F3(1 / body_inertia.x, 1 / body_inertia.y, 1 / body_inertia.z);
	float3 body_omega = omega[i];
	float3 gyr = cross(body_omega, body_inertia * body_omega);
	gyro[i] = gyr;
}

__global__ void ChKernelOffsets(int2* ids, CH_REALNUMBER4* bilaterals, uint* Body) {
	uint i = blockIdx.x * blockDim.x + threadIdx.x;
	if (i < number_of_contacts_const) {
		int2 temp_id = ids[i];
		Body[i] = temp_id.x;
		Body[i + number_of_contacts_const] = temp_id.y;
	}
	if (i < number_of_bilaterals_const) {
		Body[2 * number_of_contacts_const + i] = bilaterals[i].w;
		Body[2 * number_of_contacts_const + i + number_of_bilaterals_const] = bilaterals[i + number_of_bilaterals_const].w;
	}
}

void ChLcpSolverGPU::WarmContact(const int & i) {

}

void ChLcpSolverGPU::Preprocess(gpu_container & gpu_data) {
	gpu_data.number_of_updates = 0;
	uint number_of_contacts = gpu_data.number_of_contacts;

	uint number_of_bilaterals = gpu_data.number_of_bilaterals;
	uint number_of_objects = gpu_data.number_of_objects;
	uint number_of_constraints = gpu_data.number_of_contacts + gpu_data.number_of_bilaterals;
	gpu_data.device_gyr_data.resize(number_of_objects);

	thrust::device_vector<uint> body_num;
	thrust::device_vector<uint> update_number;

	COPY_TO_CONST_MEM(number_of_contacts);
	COPY_TO_CONST_MEM(number_of_bilaterals);
	COPY_TO_CONST_MEM(number_of_objects);
	COPY_TO_CONST_MEM(step_size);

	cudaFuncSetCacheConfig(LCP_ComputeGyro, cudaFuncCachePreferL1);
	cudaFuncSetCacheConfig(ChKernelLCPaddForces, cudaFuncCachePreferL1);
	cudaFuncSetCacheConfig(ChKernelOffsets, cudaFuncCachePreferL1);

	LCP_ComputeGyro CUDA_KERNEL_DIM(BLOCKS(number_of_objects), THREADS)(CASTF3(gpu_data.device_omg_data), CASTF3(gpu_data.device_inr_data), CASTF3(gpu_data.device_gyr_data), CASTF3(gpu_data.device_trq_data));

	ChKernelLCPaddForces CUDA_KERNEL_DIM(BLOCKS(number_of_objects), THREADS)(
			CASTF3(gpu_data.device_aux_data),
			CASTF3(gpu_data.device_inr_data),
			CASTF3(gpu_data.device_frc_data),
			CASTF3(gpu_data.device_trq_data),
			CASTF3(gpu_data.device_vel_data),
			CASTF3(gpu_data.device_omg_data));
	gpu_data.device_fap_data.resize(number_of_objects);
	Thrust_Fill(gpu_data.device_fap_data,F3(0));

	if (number_of_constraints > 0) {

		update_number.resize((number_of_constraints)* 2, 0);
		gpu_data.offset_counter.resize((number_of_constraints)* 2, 0);
		gpu_data.update_offset.resize((number_of_constraints)* 2, 0);
		body_num.resize((number_of_constraints) * 2,0);
		gpu_data.device_dgm_data.resize((number_of_constraints));

		Thrust_Fill(gpu_data.device_dgm_data,1);
		gpu_data.vel_update.resize((number_of_constraints) * 2);
		gpu_data.omg_update.resize((number_of_constraints) * 2);

		ChKernelOffsets CUDA_KERNEL_DIM(BLOCKS(number_of_constraints), THREADS) (
				CASTI2(gpu_data.device_bids_data),
				CASTF4(gpu_data.device_bilateral_data),
				CASTU1(body_num));

		Thrust_Sequence(update_number);
		Thrust_Sequence(gpu_data.update_offset);
		Thrust_Fill(gpu_data.offset_counter,0);
		Thrust_Sort_By_Key(body_num, update_number);
		Thrust_Sort_By_Key(update_number,gpu_data.update_offset);
		gpu_data.body_number = body_num;
		Thrust_Reduce_By_KeyB(gpu_data.number_of_updates,body_num,update_number,gpu_data.offset_counter);
		Thrust_Inclusive_Scan(gpu_data.offset_counter);

	}
}

void ChLcpSolverGPU::Iterate(gpu_container & gpu_data) {
	uint number_of_updates = gpu_data.number_of_updates;
	COPY_TO_CONST_MEM(number_of_updates);
	uint number_of_constraints = gpu_data.number_of_contacts + gpu_data.number_of_bilaterals;
	bool use_DEM = false;
	uint number_of_contacts = gpu_data.number_of_contacts;
	uint number_of_bilaterals = gpu_data.number_of_bilaterals;
	uint number_of_objects = gpu_data.number_of_objects;

	cudaFuncSetCacheConfig(LCP_Iteration_Contacts, cudaFuncCachePreferL1);
	cudaFuncSetCacheConfig(LCP_Iteration_Bilaterals, cudaFuncCachePreferL1);

	COPY_TO_CONST_MEM(lcp_omega_bilateral);
	COPY_TO_CONST_MEM(lcp_omega_contact);
	COPY_TO_CONST_MEM(lcp_contact_factor);
	COPY_TO_CONST_MEM(step_size);
	COPY_TO_CONST_MEM(number_of_contacts);
	COPY_TO_CONST_MEM(number_of_bilaterals);
	COPY_TO_CONST_MEM(number_of_objects);
	COPY_TO_CONST_MEM(compliance);
	COPY_TO_CONST_MEM(complianceT);
	COPY_TO_CONST_MEM(alpha);

	if (use_DEM == false) {
		LCP_Iteration_Contacts CUDA_KERNEL_DIM(BLOCKS(number_of_contacts), THREADS)(
				CASTF3(gpu_data.device_norm_data),
				CASTF3(gpu_data.device_cpta_data),
				CASTF3(gpu_data.device_cptb_data),
				CASTF1(gpu_data.device_dpth_data),
				CASTI2(gpu_data.device_bids_data),
				CASTF3(gpu_data.device_gam_data),
				CASTF1(gpu_data.device_dgm_data),
				CASTF3(gpu_data.device_aux_data),
				CASTF3(gpu_data.device_inr_data),
				CASTF4(gpu_data.device_rot_data),
				CASTF3(gpu_data.device_vel_data),
				CASTF3(gpu_data.device_omg_data),
				CASTF3(gpu_data.device_pos_data),
				CASTF3(gpu_data.vel_update),
				CASTF3(gpu_data.omg_update),
				CASTU1(gpu_data.update_offset));
	} else {
		DEM_Contacts CUDA_KERNEL_DIM(BLOCKS(number_of_contacts), THREADS)(
				CASTF3(gpu_data.device_norm_data),
				CASTF3(gpu_data.device_cpta_data),
				CASTF3(gpu_data.device_cptb_data),
				CASTF1(gpu_data.device_dpth_data),
				CASTI2(gpu_data.device_bids_data),
				CASTF3(gpu_data.device_aux_data),
				CASTF3(gpu_data.device_inr_data),
				CASTF4(gpu_data.device_rot_data),
				CASTF3(gpu_data.device_vel_data),
				CASTF3(gpu_data.device_omg_data),
				CASTF3(gpu_data.device_pos_data),
				CASTF3(gpu_data.vel_update),
				CASTF3(gpu_data.omg_update),
				CASTU1(gpu_data.update_offset));

	}
	LCP_Iteration_Bilaterals CUDA_KERNEL_DIM(BLOCKS(number_of_bilaterals), THREADS)(
			CASTF4(gpu_data.device_bilateral_data),
			CASTF3(gpu_data.device_aux_data),
			CASTF3(gpu_data.device_inr_data),
			CASTF4(gpu_data.device_rot_data),
			CASTF3(gpu_data.device_vel_data),
			CASTF3(gpu_data.device_omg_data),
			CASTF3(gpu_data.device_pos_data),
			CASTF3(gpu_data.vel_update),
			CASTF3(gpu_data.omg_update),
			CASTU1(gpu_data.update_offset),
			CASTF1(gpu_data.device_dgm_data));

}
void ChLcpSolverGPU::Reduce(gpu_container & gpu_data) {

	uint number_of_constraints = gpu_data.number_of_contacts + gpu_data.number_of_bilaterals;
	uint number_of_contacts = gpu_data.number_of_contacts;
	uint number_of_bilaterals = gpu_data.number_of_bilaterals;
	uint number_of_objects = gpu_data.number_of_objects;
	uint number_of_updates = gpu_data.number_of_updates;
	COPY_TO_CONST_MEM(number_of_contacts);
	COPY_TO_CONST_MEM(number_of_bilaterals);
	COPY_TO_CONST_MEM(number_of_objects);
	cudaFuncSetCacheConfig(LCP_Reduce_Speeds, cudaFuncCachePreferL1);
	LCP_Reduce_Speeds CUDA_KERNEL_DIM(BLOCKS( number_of_updates), THREADS)(
			CASTF3(gpu_data.device_aux_data),
			CASTF3(gpu_data.device_vel_data),
			CASTF3(gpu_data.device_omg_data),
			CASTF3(gpu_data.vel_update),
			CASTF3(gpu_data.omg_update),
			CASTU1(gpu_data.body_number),
			CASTU1(gpu_data.offset_counter),
			CASTF3(gpu_data.device_fap_data));

}
void ChLcpSolverGPU::Integrate(gpu_container & gpu_data) {

	uint number_of_constraints = gpu_data.number_of_contacts + gpu_data.number_of_bilaterals;

	bool use_DEM = false;
	uint number_of_contacts = gpu_data.number_of_contacts;
	uint number_of_bilaterals = gpu_data.number_of_bilaterals;
	uint number_of_objects = gpu_data.number_of_objects;
	uint number_of_updates = gpu_data.number_of_updates;
	COPY_TO_CONST_MEM(step_size);
	COPY_TO_CONST_MEM(number_of_contacts);
	COPY_TO_CONST_MEM(number_of_bilaterals);
	COPY_TO_CONST_MEM(number_of_objects);

	cudaFuncSetCacheConfig(LCP_Integrate_Timestep, cudaFuncCachePreferL1);
	LCP_Integrate_Timestep CUDA_KERNEL_DIM( BLOCKS(number_of_objects), THREADS)(
			CASTF3(gpu_data.device_aux_data),
			CASTF3(gpu_data.device_acc_data),
			CASTF4(gpu_data.device_rot_data),
			CASTF3(gpu_data.device_vel_data),
			CASTF3(gpu_data.device_omg_data),
			CASTF3(gpu_data.device_pos_data),
			CASTF3(gpu_data.device_lim_data));

}

__device__ inline float4 DifVelocityRho(
        const float4 & posRadA,
        const float4 & posRadB,
        const float4 & velMasA,
        const float3 & vel_XSPH_A,
        const float4 & velMasB,
        const float3 & vel_XSPH_B,
        const float4 & rhoPresMuA,
        const float4 & rhoPresMuB) {
	//float3 dist3 = Distance(posRadA, posRadB);
	//float d = length(dist3);
	//float3 gradW = GradW(dist3, posRadA.w);
	//float vAB_Dot_rAB = dot(F3(velMasA - velMasB), dist3);
	//float epsilonMutualDistance = .01f;

	//*** Artificial viscosity type 2
	//float rAB_Dot_GradW = dot(dist3, gradW);
	//float3 derivV = -velMasB.w * (rhoPresMuA.y / (rhoPresMuA.x * rhoPresMuA.x) + rhoPresMuB.y / (rhoPresMuB.x * rhoPresMuB.x)) * gradW + velMasB.w * 8.0f * mu0 * rAB_Dot_GradW / pow(rhoPresMuA.x
	//        + rhoPresMuB.x, 2) / (d * d + epsilonMutualDistance * posRadA.w * posRadA.w) * F3(velMasA - velMasB);
	//return F4(derivV, rhoPresMuA.x * velMasB.w / rhoPresMuB.x * dot(vel_XSPH_A - vel_XSPH_B, gradW));
}

__host__ __device__ void Force_Sph_SPH() {
	//	derivVelRho = DifVelocityRho(posRadA, posRadB, velMasA, vel_XSPH_A, velMasB, vel_XSPH_B, rhoPresMuA, rhoPresMuB);
	//	derivV += F3(derivVelRho);
	//	derivRho += derivVelRho.w;

}

__host__ __device__ void Force_Sph_RB() {

	//	derivVelRho = DifVelocityRho(posRadA, posRadB, velMasA, vel_XSPH_A, velMasB, vel_XSPH_B, rhoPresMuA, rhoPresMuB);
	//	derivV += F3(derivVelRho);
	//	derivRho += derivVelRho.w;
	//
	//	derivVelRho = DifVelocityRho(posRadA, posRadB, velMasA, vel_XSPH_A, velMasB, vel_XSPH_B, rhoPresMuA, rhoPresMuB);
	//	derivV += F3(derivVelRho);
	//	derivRho += derivVelRho.w;

}

void ForceSPH(
        thrust::device_vector<float4> & posRadD,
        thrust::device_vector<float4> & velMasD,
        thrust::device_vector<float3> & vel_XSPH_D,
        thrust::device_vector<float4> & rhoPresMuD,
        thrust::device_vector<uint> & bodyIndexD,
        thrust::device_vector<float4> & derivVelRhoD) {

	//Collide All
	//for each sph contact compute force
	//for each sph-rigid contact compute force

}
void UpdateFluid(
        thrust::device_vector<float4> & posRadD,
        thrust::device_vector<float4> & velMasD,
        thrust::device_vector<float3> & vel_XSPH_D,
        thrust::device_vector<float4> & rhoPresMuD,
        thrust::device_vector<float4> & derivVelRhoD,
        const thrust::host_vector<int3> & referenceArray,
        float dT) {
	//	int2 updatePortion = I2(referenceArray[0]);
	//	//int2 updatePortion = I2(referenceArray[0].x, referenceArray[0].y);
	//	cudaMemcpyToSymbolAsync(dTD, &dT, sizeof(dT));
	//	cudaMemcpyToSymbolAsync(updatePortionD, &updatePortion, sizeof(updatePortion));
	//
	//	uint nBlock_UpdateFluid, nThreads;
	//	computeGridSize(updatePortion.y - updatePortion.x, 128, nBlock_UpdateFluid, nThreads);
	//	UpdateKernelFluid<<<nBlock_UpdateFluid, nThreads>>>(F4CAST(posRadD), F4CAST(velMasD), F3CAST(vel_XSPH_D), F4CAST(rhoPresMuD), F4CAST(derivVelRhoD));
	//	cudaThreadSynchronize();
	//	CUT_CHECK_ERROR("Kernel execution failed: UpdateKernelFluid");
}
void ChLcpSolverGPU::RunTimeStep(float step, gpu_container & gpu_data) {
	/*
	 posRadD pos and radius
	 velMasD velocity mass
	 vel_XSPH_D stabilization velocity
	 rhoPresMuD density pressure visc type
	 derivVelRhoD dv/dt drho/dt
	 referenceArray start-end pair for each group of spheres making up RB
	 mNSpheres total spheres
	 */

	//thrust::device_vector<float4> posRadD2 = posRadD;
	//thrust::device_vector<float4> velMasD2 = velMasD;
	//thrust::device_vector<float4> rhoPresMuD2 = rhoPresMuD;
	//thrust::device_vector<float4> posRadRigidD2 = posRadRigidD;
	///thrust::device_vector<float4> velMassRigidD2 = velMassRigidD;
	//thrust::device_vector<float3> omegaLRF_D2 = omegaLRF_D;
	//thrust::device_vector<float3> vel_XSPH_D(mNSpheres);

	//ForceSPH(posRadD, velMasD, vel_XSPH_D, rhoPresMuD, bodyIndexD, derivVelRhoD, referenceArray, mNSpheres, SIDE);
	//UpdateFluid(posRadD2, velMasD2, vel_XSPH_D, rhoPresMuD2, derivVelRhoD, referenceArray, 0.5 * delT);
	//ForceSPH(posRadD2, velMasD2, vel_XSPH_D, rhoPresMuD2, bodyIndexD, derivVelRhoD, referenceArray, mNSpheres, SIDE);
	//UpdateFluid(posRadD, velMasD, vel_XSPH_D, rhoPresMuD, derivVelRhoD, referenceArray, delT);

	//reduce forces of rigid bodies
	lcp_omega_contact = omega;
	step_size = step;
	Preprocess(gpu_data);
	bool use_DEM = false;
	uint number_of_constraints = gpu_data.number_of_contacts + gpu_data.number_of_bilaterals;
	if (number_of_constraints != 0) {
		for (iteration_number = 0; iteration_number < max_iterations; iteration_number++) {
			Iterate(gpu_data);
			Reduce(gpu_data);
			//if (use_DEM == true) {
			//	break;
			//}
			if (iteration_number > 50 && iteration_number % 50 == 0) {
				if (Max_DeltaGamma(gpu_data.device_dgm_data) < tolerance) {
					break;
				}
			}
		}
	}
	Integrate(gpu_data);
}
float ChLcpSolverGPU::Max_DeltaGamma(device_vector<float> &device_dgm_data) {
	return Thrust_Max(device_dgm_data);
}
float ChLcpSolverGPU::Min_DeltaGamma(device_vector<float> &device_dgm_data) {
	return Thrust_Min(device_dgm_data);
}
float ChLcpSolverGPU::Avg_DeltaGamma(uint number_of_constraints, device_vector<float> &device_dgm_data) {

	float gamma = (Thrust_Total(device_dgm_data)) / float(number_of_constraints);
	//cout << gamma << endl;
	return gamma;
}
__global__ void Compute_KE(float3* vel, float3* aux, float* ke) {
	unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
	if (i >= number_of_objects_const) {
		return;
	}
	float3 velocity = vel[i];
	ke[i] = .5 / aux[i].z * dot(velocity, velocity);
}
float ChLcpSolverGPU::Total_KineticEnergy(gpu_container & gpu_data) {

	thrust::device_vector<float> device_ken_data;
	device_ken_data.resize(gpu_data.number_of_objects);
	Compute_KE CUDA_KERNEL_DIM(BLOCKS(gpu_data.number_of_objects), THREADS)(CASTF3(gpu_data.device_vel_data), CASTF3(gpu_data.device_aux_data), CASTF1(device_ken_data));
	return (Thrust_Total(device_ken_data));
}

