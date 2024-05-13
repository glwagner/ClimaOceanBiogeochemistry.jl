# # Nutrients, plankton, bacteria, detritus
#
# This example illustrates how to use ClimaOceanBiogeochemistry's
# `CarbonAlkalinityNutrients` model in a single column context.

using ClimaOceanBiogeochemistry: CarbonAlkalinityNutrients
using ClimaOceanBiogeochemistry.CarbonSystemSolvers.UniversalRobustCarbonSolver: UniversalRobustCarbonSystem
using ClimaOceanBiogeochemistry.CarbonSystemSolvers: CarbonChemistryCoefficients

using Oceananigans
using Oceananigans.Units
using Oceananigans.TurbulenceClosures: CATKEVerticalDiffusivity

using Printf
using CairoMakie

# ## A single column grid
#
# We set up a single column grid with 4 m grid spacing that's 256 m deep:

grid = RectilinearGrid(size = 64,
                       z = (-256meters, 0),
                       topology = (Flat, Flat, Bounded))

# ## Buoyancy that depends on temperature and salinity
# We use the `SeawaterBuoyancy` model with a linear equation of state,
# where thermal expansion
αᵀ = 2e-4
#and haline contraction
βˢ = 8e-4

# ## Boundary conditions
#
# We calculate the surface temperature flux associated with surface cooling of
# 200 W m⁻², reference density `ρₒ`, and heat capacity `cᴾ`,
# To illustrate the dynamics of `CarbonAlkalinityNutrients`, this strong convection
# drives turbulent mixing for 4 days, and then abruptly shuts off. 
# Once the convective turbulence dies down, plankton start to grow.
Qʰ = 400.0  # W m⁻², surface _heat_ flux
ρₒ = 1026.0 # kg m⁻³, average density at the surface of the world ocean
cᴾ = 3991.0 # J K⁻¹ kg⁻¹, typical heat capacity for seawater

Qᵀ(t) = ifelse(t < 5days, Qʰ / (ρₒ * cᴾ), 0.0) # K m s⁻¹, surface _temperature_ flux

# Finally, we impose a temperature gradient `dTdz` both initially and at the
# bottom of the domain, culminating in the boundary conditions on temperature,

dTdz = 0.01 # K m⁻¹

T_bcs = FieldBoundaryConditions(top    = FluxBoundaryCondition(Qᵀ),
                                bottom = GradientBoundaryCondition(dTdz))


# These are filled in compute_co₂_flux!
ocean_co₂ = Field{Center, Center, Nothing}(grid)
atmos_co₂ = Field{Center, Center, Nothing}(grid)

# For air-sea CO₂ fluxes, we use a FluxBoundaryCondition for the "top" of the DIC tracer.
# We'll write a callback to calculate the flux every time step.
co₂_flux = Field{Center, Center, Nothing}(grid)

dic_bcs  = FieldBoundaryConditions(top = FluxBoundaryCondition(co₂_flux))

### We put the pieces together ###
# The important line here is `biogeochemistry = CarbonAlkalinityNutrients()`.
# We use all default parameters.
model = HydrostaticFreeSurfaceModel(; 
    grid,
    biogeochemistry     = CarbonAlkalinityNutrients(; 
        grid,
        ),
    closure             = ScalarDiffusivity(; κ=1e-5),    
    tracers             = (:T, :S, :DIC, :ALK, :PO₄, :NO₃, :DOP, :POP, :Fe),
    tracer_advection    = WENO(),
    buoyancy            = SeawaterBuoyancy(
        equation_of_state  = LinearEquationOfState(
            thermal_expansion  = αᵀ,
            haline_contraction = βˢ
            ),
        ),
    boundary_conditions = (; T=T_bcs, DIC=dic_bcs),
    )

# ## Initial conditions
#
## Temperature initial condition: a stable density gradient with random noise superposed.
## Random noise damped at top and bottom
Ξ(z) = randn() * z / model.grid.Lz * (1 + z / model.grid.Lz)
Tᵢ(z) = 20 + dTdz * z + dTdz * model.grid.Lz * 1e-6 * Ξ(z)
Sᵢ(z) = 35

# We initialize the model with reasonable nutrient concentrations
DICᵢ(z) = 2.1   # mol/m³ 
ALKᵢ(z) = 2.35   # mol/m³ 
PO₄ᵢ(z) = 2.5e-3 # mol/m³ 
NO₃ᵢ(z) = 36e-3  # mol/m³ 
DOPᵢ(z) = 0.0    # mol/m³ 
POPᵢ(z) = 0.0    # mol/m³ 
Feᵢ(z)  = 1.e-6  # mol/m³

set!(
    model, 
    T   = Tᵢ,
    S   = Sᵢ, 
    DIC = DICᵢ, 
    ALK = ALKᵢ, 
    PO₄ = PO₄ᵢ, 
    NO₃ = NO₃ᵢ, 
    DOP = DOPᵢ, 
    POP = POPᵢ, 
    Fe  = Feᵢ
    )

# ## A simulation of physical-biological interaction
# 
# We construct a simple simulation that emits a message every 10 iterations
# and outputs tracer fields.

simulation = Simulation(model, Δt=10minutes, stop_time=30days)

# We add a `TimeStepWizard` callback to adapt the simulation's time-step,
wizard = TimeStepWizard(cfl=0.2, max_change=1.1, max_Δt=60minutes)
simulation.callbacks[:wizard] = Callback(wizard, IterationInterval(10))


DIC₀ = Field{Center, Center, Nothing}(grid)
ALK₀ = Field{Center, Center, Nothing}(grid)
"""
Function to print DIC, ALK, and CO₂ flux tendency during the simulation
"""
function progress(simulation) 
    @printf("Iteration: %d, time: %s\n", 
        iteration(simulation), 
        prettytime(simulation),
        )

    if (iteration(simulation) == 1)
        # Establish and set initial values for the anomaly fields
        DIC₀[1, 1, 1] = simulation.model.tracers.DIC[
            1, 1, simulation.model.grid.Nz,
            ]
        ALK₀[1, 1, 1] = simulation.model.tracers.ALK[
            1, 1, simulation.model.grid.Nz,
            ] 
    else
        @printf("Surface DIC (x10⁻⁷ mol m⁻³ s⁻¹): %.12f\n", 
            ((simulation.model.tracers.DIC[1, 1, grid.Nz]-
                DIC₀[1, 1, 1])/simulation.model.timestepper.previous_Δt) * 1e7)
        @printf("Surface ALK (x10⁻⁷ mol m⁻³ s⁻¹): %.12f\n", 
            ((simulation.model.tracers.ALK[1, 1, grid.Nz]-
                ALK₀[1, 1, 1])/simulation.model.timestepper.previous_Δt) * 1e7)
        @printf("Surface CO₂ flux (x10⁻⁷ mol m⁻³ s⁻¹): %.12f\n", 
            simulation.model.tracers.DIC.boundary_conditions.top.condition[1,1] * 1e7)

        # update the anomaly fields
        DIC₀[1, 1, 1] = simulation.model.tracers.DIC[
                1, 1, simulation.model.grid.Nz,
                ]
        ALK₀[1, 1, 1] = simulation.model.tracers.ALK[
                1, 1, simulation.model.grid.Nz,
                ]    
    end
end

simulation.callbacks[:progress] = Callback(progress, IterationInterval(10))

# I really want the option to take these from the model
Base.@kwdef struct Pᶠˡᵘˣᶜᵒ²{FT}
    surface_wind_speed   :: FT = 10. # ms⁻¹
    applied_pressure     :: FT = 0.0 # atm
    atmospheric_pCO₂     :: FT = 280e-6 # atm
    exchange_coefficient :: FT = 0.337 # cm hr⁻¹
    silicate_conc        :: FT = 15e-6 # mol kg⁻¹
    initial_pH_guess     :: FT = 8.0
    reference_density    :: FT = 1024.5 # kg m⁻³
    schmidt_dic_coeff0   :: FT = 2116.8
    schmidt_dic_coeff1   :: FT = 136.25 
    schmidt_dic_coeff2   :: FT = 4.7353 
    schmidt_dic_coeff3   :: FT = 9.2307e-2
    schmidt_dic_coeff4   :: FT = 7.555e-4
    schmidt_dic_coeff5   :: FT = 660.0
end

# Build operation for CO₂ flux calculation, used in callback below to calculate every time step
"""
    compute_co₂_flux!(simulation)
    
Returns the tendency of DIC in the top layer due to air-sea CO₂ flux
using the piston velocity formulation of Wanninkhof (1992) and the
solubility/activity of CO₂ in seawater.
"""
@inline function compute_co₂_flux!(simulation)
# conversion factor from cm/hr to m/s
    cmhr⁻¹_per_ms⁻¹ = 1 / 3.6e5

# get coefficients from Pᶠˡᵘˣᶜᵒ² struct
# I really want the option to take these from the model
    (; surface_wind_speed, 
       applied_pressure,
       atmospheric_pCO₂, 
       exchange_coefficient, 
       silicate_conc, 
       initial_pH_guess, 
       reference_density,
       schmidt_dic_coeff0, 
       schmidt_dic_coeff1, 
       schmidt_dic_coeff2, 
       schmidt_dic_coeff3, 
       schmidt_dic_coeff4,    
       ) = Pᶠˡᵘˣᶜᵒ²()

    U₁₀      = surface_wind_speed  
    Δpᵦₐᵣ    = applied_pressure # (i.e. Pˢᵘʳᶠ-Pᵃᵗᵐ)
    pCO₂ᵃᵗᵐ  = atmospheric_pCO₂    
    Kʷₐᵥₑ    = exchange_coefficient
    Siᵀ      = silicate_conc       
    pH       = initial_pH_guess
    ρʳᵉᶠ     = reference_density
    a₀ˢᶜᵈⁱᶜ   = schmidt_dic_coeff0 
    a₁ˢᶜᵈⁱᶜ   = schmidt_dic_coeff1 
    a₂ˢᶜᵈⁱᶜ   = schmidt_dic_coeff2 
    a₃ˢᶜᵈⁱᶜ   = schmidt_dic_coeff3 
    a₄ˢᶜᵈⁱᶜ   = schmidt_dic_coeff4 
    a₅ˢᶜᵈⁱᶜ   = schmidt_dic_coeff5 
    co₂_flux = simulation.model.tracers.DIC.boundary_conditions.top.condition

    @inbounds for i in 1:co₂_flux.grid.Nx
        @inbounds for j in 1:co₂_flux.grid.Ny
        # access model fields
            Θᶜ = simulation.model.tracers.T[
                    simulation.model.grid.Nx,
                    simulation.model.grid.Ny,
                    simulation.model.grid.Nz,
                    ]
            Sᴬ = simulation.model.tracers.S[
                    simulation.model.grid.Nx,
                    simulation.model.grid.Ny,
                    simulation.model.grid.Nz,
                    ]
            Cᵀ = simulation.model.tracers.DIC[
                    simulation.model.grid.Nx,
                    simulation.model.grid.Ny,
                    simulation.model.grid.Nz,
                    ]/ρʳᵉᶠ # Convert mol m⁻³ to mol kg⁻¹
            Aᵀ = simulation.model.tracers.ALK[
                    simulation.model.grid.Nx,
                    simulation.model.grid.Ny,
                    simulation.model.grid.Nz,
                    ]/ρʳᵉᶠ # Convert mol m⁻³ to mol kg⁻¹
            Pᵀ = simulation.model.tracers.PO₄[
                    simulation.model.grid.Nx,
                    simulation.model.grid.Ny,
                    simulation.model.grid.Nz,
                    ]/ρʳᵉᶠ # Convert mol m⁻³ to mol kg⁻¹

        # compute oceanic pCO₂ using the UniversalRobustCarbonSystem solver
        # Returns ocean pCO₂ (in atm) and atmosphere/ocean solubility coefficients (mol kg⁻¹ atm⁻¹)
        (; pCO₂ᵒᶜᵉ, Pᵈⁱᶜₖₛₒₗₐ, Pᵈⁱᶜₖₛₒₗₒ) = 
            UniversalRobustCarbonSystem(
                    Θᶜ, Sᴬ, Δpᵦₐᵣ, Cᵀ, Aᵀ, Pᵀ, Siᵀ, pH, pCO₂ᵃᵗᵐ,
                    )

        # compute schmidt number for DIC
        Cˢᶜᵈⁱᶜ =  ( a₀ˢᶜᵈⁱᶜ - 
                    a₁ˢᶜᵈⁱᶜ * Θᶜ + 
                    a₂ˢᶜᵈⁱᶜ * Θᶜ^2 - 
                    a₃ˢᶜᵈⁱᶜ * Θᶜ^3 + 
                    a₄ˢᶜᵈⁱᶜ * Θᶜ^4 
                  )/a₅ˢᶜᵈⁱᶜ

        # compute gas exchange coefficient/piston velocity and correct with Schmidt number
        Kʷ =  (
               (Kʷₐᵥₑ * cmhr⁻¹_per_ms⁻¹) * U₁₀^2
              ) / sqrt(Cˢᶜᵈⁱᶜ)    
            
        # compute co₂ flux (-ve for uptake, +ve for outgassing since convention is +ve upwards in the soda)
        co₂_flux[
            simulation.model.grid.Nx,
            simulation.model.grid.Ny,
            simulation.model.grid.Nz
            ] = - Kʷ * (
                        pCO₂ᵃᵗᵐ * Pᵈⁱᶜₖₛₒₗₐ - 
                        pCO₂ᵒᶜᵉ * Pᵈⁱᶜₖₛₒₗₒ
                       ) * ρʳᵉᶠ # Convert mol kg⁻¹ m s⁻¹ to mol m⁻² s⁻¹

        # store the oceanic and atmospheric CO₂ concentrations into Fields
        ocean_co₂[
            simulation.model.grid.Nx,
            simulation.model.grid.Ny,
            simulation.model.grid.Nz,
            ] = pCO₂ᵒᶜᵉ
        atmos_co₂[
            simulation.model.grid.Nx,
            simulation.model.grid.Ny,
            simulation.model.grid.Nz,
            ] = pCO₂ᵃᵗᵐ 

        end
    end
    return nothing
end

add_callback!(simulation, compute_co₂_flux!)

# Output writer
filename = "single_column_carbon_alkalinity_nutrients.jld2"

simulation.output_writers[:fields] = JLD2OutputWriter(model, model.tracers;
                                                      filename,
                                                      schedule = TimeInterval(20minutes),
                                                      overwrite_existing = true)

filename_diags = "single_column_carbon_alkalinity_nutrients_co2flux.jld2"

outputs = (; co₂_flux, ocean_co₂, atmos_co₂)
simulation.output_writers[:jld2] = JLD2OutputWriter(model, outputs;
                                                    filename = filename_diags,
                                                    schedule = TimeInterval(20minutes),
                                                    overwrite_existing = true)
run!(simulation)

# ## Visualization
#
# All that's left is to visualize the results.

Tt   = FieldTimeSeries(filename, "T")
St   = FieldTimeSeries(filename, "S")
DICt = FieldTimeSeries(filename, "DIC")
Alkt = FieldTimeSeries(filename, "ALK")
PO₄t = FieldTimeSeries(filename, "PO₄")
NO₃t = FieldTimeSeries(filename, "NO₃")
DOPt = FieldTimeSeries(filename, "DOP")
POPt = FieldTimeSeries(filename, "POP")
Fet  = FieldTimeSeries(filename, "Fe")
CO₂t = FieldTimeSeries(filename_diags, "co₂_flux")
apCO₂t = FieldTimeSeries(filename_diags, "atmos_co₂")
opCO₂t = FieldTimeSeries(filename_diags, "ocean_co₂")

tt = Tt.times
nt = length(tt)
z  = znodes(Tt)

CO₂_flux_time_series   = [CO₂t[1, 1, 1, i] for i in 1:nt]
pCO₂_ocean_time_series = [opCO₂t[1, 1, 1, i] for i in 1:nt]
pCO₂_atmos_time_series = [apCO₂t[1, 1, 1, i] for i in 1:nt]

fig = Figure(size=(1200, 1200))
n = Observable(1)

axb = Axis(fig[1:4, 1], xlabel="Temperature (K)", ylabel="z (m)")
axC = Axis(fig[1:4, 2], xlabel="DIC/ALK Concentration (mol m⁻³)")
axN = Axis(fig[1:4, 3], xlabel="Inorganic Nutrient concentration (mmol m⁻³)")
axD = Axis(fig[1:4, 4], xlabel="Organic Nutrient concentration (mmol m⁻³)")
axF = Axis(fig[5:6, 1:4], ylabel="Air-sea CO₂ fluxes (x1e7 mol m⁻² s⁻¹)", xlabel="Time (days)")
axP = Axis(fig[5:6, 1:4], ylabel="pCO₂ (μatm)",yticklabelcolor = :red, yaxisposition = :right)

xlims!(axb, 15, 20)
xlims!(axC, 1.8, 2.8)
xlims!(axN, 0, 40)
xlims!(axD, 0, 25)
xlims!(axF, -1, 31)
xlims!(axP, -1, 31)
ylims!(axF, -2, 2)
ylims!(axP, 250, 450)

#slider = Slider(fig[2, 1:4], range=1:nt, startvalue=1)
#n = slider.value

title = @lift @sprintf("Convecting nutrients at t = %d days", tt[$n] / days)
Label(fig[0, 1:4], title)

Tn = @lift interior(Tt[$n], 1, 1, :)
DICn = @lift interior(DICt[$n], 1, 1, :) 
Alkn = @lift interior(Alkt[$n], 1, 1, :) 
PO₄n = @lift interior(PO₄t[$n], 1, 1, :) * 10e3
NO₃n = @lift interior(NO₃t[$n], 1, 1, :) * 1e3
DOPn = @lift interior(DOPt[$n], 1, 1, :) * 1e6
POPn = @lift interior(POPt[$n], 1, 1, :) * 1e6
Fen  = @lift interior(Fet[$n],  1, 1, :) * 1e6
CO₂_flux_points = Observable(Point2f[(tt[1], 
                    (CO₂_flux_time_series[1] * 1e7))])
pCO₂_ocean_points = Observable(Point2f[(tt[1], 
                    (pCO₂_ocean_time_series[1] * 1e6))])
pCO₂_atmos_points = Observable(Point2f[(tt[1], 
                    (pCO₂_atmos_time_series[1] * 1e6))])

lines!(axb, Tn,   z)
lines!(axC, DICn, z, label="DIC")
lines!(axC, Alkn, z, label="ALK")
lines!(axN, PO₄n, z, label="Phosphate (x10)")
lines!(axN, NO₃n, z, label="Nitrate")
lines!(axN, Fen,  z, label="Iron (x1e-6)")
lines!(axD, DOPn, z, label="DOP (x1e-6)")
lines!(axD, POPn, z, label="POP (x1e-6)")

scatter!(axP, pCO₂_ocean_points; marker = :circle, markersize = 4, color = :blue, label="ocean pCO₂")
scatter!(axP, pCO₂_atmos_points; marker = :circle, markersize = 4, color = :red, label="atmos pCO₂")
scatter!(axF, CO₂_flux_points;   marker = :circle, markersize = 4, color = :black)

axislegend(axC)
axislegend(axN)
axislegend(axD)
axislegend(axP)

record(fig, "carbon_alkalinity_nutrients.mp4", 1:nt, framerate=48) do nn
    n[] = nn
    new_point = Point2(tt[nn] / days, (CO₂_flux_time_series[nn] * 1e7))
    CO₂_flux_points[]  = push!(CO₂_flux_points[], new_point)

    new_point = Point2(tt[nn] / days, (pCO₂_ocean_time_series[nn] * 1e6))
    pCO₂_ocean_points[]  = push!(pCO₂_ocean_points[], new_point)

    new_point = Point2(tt[nn] / days, (pCO₂_atmos_time_series[nn] * 1e6))
    pCO₂_atmos_points[]  = push!(pCO₂_atmos_points[], new_point)
end
#nothing #hide
fig
# ![](carbon_alkalinity_nutrients.mp4)
