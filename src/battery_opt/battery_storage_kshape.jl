# imports
using JuMP
using Clp
using PyCall
using PyPlot
using DataFrames
plt = PyPlot


unshift!(PyVector(pyimport("sys")["path"]), "") # add current path to search path

util_path = normpath(joinpath(pwd(),"..","utils"))
unshift!(PyVector(pyimport("sys")["path"]), util_path) # add util path to search path
@pyimport load_clusters

# convert Euro to US dollars
# introduced because the clusters generated by the python script are in EUR for GER
function get_EUR_to_USD(region)
   if region =="GER"
     ret = 1.109729
   else
     ret =1
   end
   return ret
end

# battery storage optimization problem
function run_opt(el_price, weight=1, prnt=false)
  num_periods = size(el_price,2); # number of periods, 1day, one week, etc.
  num_hours = size(el_price,1); # hours per period (24 per day, 48 per 2days)

  # time steps
  del_t = 1; # hour

  # example battery Southern California Edison
  P_battery = 100; # MW
  E_battery = 400; # MWh
  eff_Storage_in = 0.95;
  eff_Storage_out = 0.95;
  #Stor_init = 0.5;

  # optimization
  # Sets
  # time
  t_max = num_hours;

  E_in_arr = zeros(num_hours,num_periods)
  E_out_arr = zeros(num_hours,num_periods)
  stor = zeros(num_hours +1,num_periods)

  obj = zeros(num_periods);
  m= Model(solver=ClpSolver() )

  # hourly energy output
  @variable(m, E_out[t=1:t_max] >= 0) # kWh
  # hourly energy input
  @variable(m, E_in[t=1:t_max] >= 0) # kWh
  # storage level
  @variable(m, Stor_lev[t=1:t_max+1] >= 0) # kWh

  @variable(m,0 <= Stor_init <= 1) # this as a variable ensures

  # maximum battery power
  for t=1:t_max
    @constraint(m, E_out[t] <= P_battery*del_t)
    @constraint(m, E_in[t] <= P_battery*del_t)
  end

  # maximum storage level
  for t=1:t_max+1
    @constraint(m, Stor_lev[t] <= E_battery)
  end

  # battery energy balance
  for t=1:t_max
    @constraint(m,Stor_lev[t+1] == Stor_lev[t] + eff_Storage_in*del_t*E_in[t]-(1/eff_Storage_out)*del_t*E_out[t])
  end

  # initial storage level
  @constraint(m,Stor_lev[1] == Stor_init*E_battery)
  @constraint(m,Stor_lev[t_max+1] >= Stor_lev[1])

  for i =1:num_periods
    #objective
    @objective(m, Max, sum((E_out[t] - E_in[t])*el_price[t,i] for t=1:t_max) )
    status = solve(m)

    if weight ==1
      obj[i] = getobjectivevalue(m)
    else
      obj[i] = getobjectivevalue(m) * weight[i] * 365
    end
    E_in_arr[:,i] = getvalue(E_in)'
    E_out_arr[:,i] = getvalue(E_out)
    stor[:,i] = getvalue(Stor_lev)
  end

  # plots
  if(prnt)
    figure()
    for i=1:num_periods
      plt.plot(stor[:,i], label=string("stor lev: ", i))
      plt.legend()
    end

    figure()
    for i=1:num_periods
      plt.plot(E_in_arr[:,i],label=string("E_in: ",i))
      plt.plot(E_out_arr[:,i], label=string("E_out: ",i))
      plt.legend()
    end
  end # prnt

  return obj
end # run_opt()

function plot_clusters(k_plot,kshape_centroids,n_k,n_init)

  for k=1:n_k

    # plot centroids for verification 
    if k==k_plot
      figure()
      for i=1:n_init
        plot(kshape_centroids[k][:,:,i]',color="0.75")
      end
      #data = Array(readtable(normpath(joinpath(pwd(),"..","..","data","kshape_results",string(region_str, "Elec_Price_kmeans_","kshape","_","cluster", "_", k,".txt"))), separator = '\t', header = false))/get_EUR_to_USD(region);
      #plot(data',color="red")
      best = kshape_centroids[k][:,:,ind_best_dist[k]] 
      plot(best',color="blue")
    end
  end
  if is_linux()
    plt.show()
  end
end # plot_clusters()


###########################################
####### main function ######################

# set working directory here
close("all")


#### DATA INPUT ######

# region:
region = "GER"   # "CA"   "GER"
n_k=9
n_init =1000

# read in original data
if region =="CA"
  region_str = ""
  region_data = normpath(joinpath(pwd(),"..","..","data","el_prices","ca_2015_orig.txt"))
else
  region_str = "GER_"
  region_data = normpath(joinpath(pwd(),"..","..","data","el_prices","GER_2015_elPrice.txt"))
end
data_orig = Array(readtable(region_data, separator = '\t', header = false)) 
data_orig_daily = reshape(data_orig,24,365)
 
# Load kshape clusters 
# calc hourly mean and sdv, Note: For GER, these are in EUR, since the original data is in EUR
hourly_mean = zeros(size(data_orig_daily)[1])
hourly_sdv = zeros(size(data_orig_daily)[1])
for i=1:size(data_orig_daily)[1]
  hourly_mean[i] = mean(data_orig_daily[i,:])
  hourly_sdv[i] = std(data_orig_daily[i,:])
end

 # initialize dictionaries of the loaded data (key: number of clusters)
kshape_centroids = Dict() 
kshape_labels = Dict()
# kshape_dist_daily = Dict()
kshape_dist = Dict()
kshape_dist_all = Dict()
kshape_iterations = Dict()
ind_conv = Dict()
num_conv = zeros(Int32,n_k) # number of converged values
kshape_weights = Dict()


for k=1:n_k 
  kshape_iterations[k] = load_clusters.load_pickle(normpath(joinpath(pwd(),"..","..","data","kshape_results",region * "iterations_kshape_" * string(k) * ".pkl")))
  ind_conv[k] = find(collect(kshape_iterations[k]) .< 19999)  # only converged values - collect() transforms tuple to array
  num_conv[k] = length(ind_conv[k])
  kshape_iterations[k] = kshape_iterations[k][ind_conv[k]] #only converged values
  kshape_centroids_in = load_clusters.load_pickle(normpath(joinpath(pwd(),"..","..","data","kshape_results", region * "_centroids_kshape_" * string(k) * ".pkl")))
  #### back transform centroids from normalized data
  kshape_centroids[k] = zeros(size(kshape_centroids_in[1])[1],size(kshape_centroids_in[1])[2],num_conv[k]) # only converged values
  for i=1:num_conv[k]
    kshape_centroids[k][:,:,i] = (kshape_centroids_in[ind_conv[k][i]].* hourly_sdv' + ones(k)*hourly_mean')
  end
  kshape_labels[k] = load_clusters.load_pickle(normpath(joinpath(pwd(),"..","..","data","kshape_results",region * "labels_kshape_" * string(k) * ".pkl"))) 
  kshape_dist[k] = load_clusters.load_pickle(normpath(joinpath(pwd(),"..","..","data","kshape_results",region * "distance_kshape_" * string(k) * ".pkl")))[ind_conv[k]] # only converged
  kshape_dist_all[k] = load_clusters.load_pickle(normpath(joinpath(pwd(),"..","..","data","kshape_results",region * "distance_kshape_" * string(k) * ".pkl")))
  # calculate weights
  kshape_weights[k] = zeros(size(kshape_centroids[k][:,:,1])[1],num_conv[k]) # only converged
  for i=1:num_conv[k]
    for j=1:length(kshape_labels[k][ind_conv[k][i]])
        kshape_weights[k][kshape_labels[k][ind_conv[k][i]][j]+1,i] +=1
    end
    kshape_weights[k][:,i] = kshape_weights[k][:,i]/length(kshape_labels[k][ind_conv[k][i]])
  end


end #k=1:n_k


# optimization on original data
revenue_orig_daily = sum(run_opt(data_orig_daily));

# optimization on kshape data
revenue_ksh = zeros(n_init,n_k)
for k=1:n_k
  for i=1:num_conv[k]
    revenue_ksh[i,k] = sum(run_opt(kshape_centroids[k][:,:,i]',kshape_weights[k][:,i],false));
  end
end

 # find best distance 
ind_best_dist = zeros(Int32,n_k)
rev_best_dist = zeros(n_k)
for k=1:n_k
  ind_best_dist[k] = findmin(kshape_dist[k])[2]
  rev_best_dist[k] = revenue_ksh[ind_best_dist[k],k]
end


 ### print some convergence statistics ###
for k=1:n_k
  println("Number of converged cases at k=",k,": ",num_conv[k])
end


 ###### Figures ########

# Boxplot revenue
figure()
boxplot(revenue_ksh/1e6)
hold
plt.plot(1:n_k,rev_best_dist/1e6,color="blue",lw=2,label="best distance") 
plt.plot(1:n_k,revenue_orig_daily/1e6*ones(n_k),label="365 days",color="c",lw=3)
plt.xlabel("Number of clusters",fontsize=25)
if region == "CA"
  plt.ylabel("Revenue [Mio USD/year]",fontsize=25)
else
  plt.ylabel("Revenue [Mio EUR/year]",fontsize=25)
end
plt.ylim(3000000*1e-6, 6500000*1e-6 )
ax  =axes()
ax[:tick_params]("both")
plt.title("k_shape "*string(n_init)*" initial runs" )
plt.legend(loc=2,fontsize=20)
plt.tight_layout()

if is_linux()
  plt.show()
end

